//
//  Transmission.swift
//  Burrow
//
//  Created by Jaden Geller on 4/17/16.
//
//

import Foundation

public struct TransmissionManager {
    public let domain: Domain
    
    public init(domain: Domain) {
        self.domain = domain
    }
}

private func value(from attributes: [String : String], forExpectedKey key: String) throws -> String {
    guard let value = attributes[key] else {
        throw ShovelError(code: .unexpectedServerResponse, reason: "Response missing \"\(key)\" key.")
    }
    return value
}

private func requireSuccess(expectedValue: String, from attributes: [String : String]) throws {
    let foundValue = try value(from: attributes, forExpectedKey: "success")
    precondition(["True", "False"].contains(foundValue))
    guard foundValue == "True" else {
        throw ShovelError(code: .serverErrorResponse, reason: attributes["error"])
    }
}

private func requireValue(expectedValue: String, from attributes: [String : String], forExpectedKey key: String) throws {
    let foundValue = try value(from: attributes, forExpectedKey: key)
    guard foundValue == expectedValue else {
        throw ShovelError(code: .unexpectedServerResponse, reason: "Expected \"\(expectedValue)\" value for \"\(key)\" key. Found \"\(foundValue)\".")
    }
}

extension TransmissionManager {
    private static let queue = dispatch_queue_create("TransmissionManager", DISPATCH_QUEUE_CONCURRENT)
}

extension TransmissionManager {
    private func begin() throws -> String {
        let message = try ServerMessage.withQuery(
            domain: domain.prepending("begin").prepending(NSUUID().UUIDString),
            recordClass: .internet,
            recordType: .txt,
            useTCP: true,
            bufferSize: 4096
        )
        let attributes = try TXTRecord.parseAttributes(message.value)

        try requireValue("True", from: attributes, forExpectedKey: "success")
        let transmissionId = try value(from: attributes, forExpectedKey: "transmission_id")

        return transmissionId
    }
    
    private func end(transmissionId: String, count: Int) throws -> NSData {
        let message = try ServerMessage.withQuery(
            domain: domain.prepending("end").prepending(transmissionId).prepending(String(count)),
            recordClass: .internet,
            recordType: .txt,
            useTCP: true,
            bufferSize: 4096
        )
        let attributes = try TXTRecord.parseAttributes(message.value)
        try requireValue("True", from: attributes, forExpectedKey: "success")

        let contents = try value(from: attributes, forExpectedKey: "contents")
        guard let data = NSData(base64EncodedString: contents, options: []) else {
            throw ShovelError(
                code: .unexpectedServerResponse,
                reason: "Unable to decode contents as Base64.",
                object: contents
            )
        }
        return data
    }
    
    private func transmit(data: NSData) throws -> NSData {
        let transmissionId = try begin()
        
        let continueDomain = domain.prepending("continue").prepending(transmissionId)
        let domains = TransmissionManager.package(arbitraryData: data, underDomain: { index in
            continueDomain.prepending(String(index))
        })

        let group = dispatch_group_create()
        var count = 0
        for domain in domains {
            count += 1
            dispatch_group_async(group, TransmissionManager.queue) {
                do {
                    let message = try ServerMessage.withQuery(
                        domain: domain,
                        recordClass: .internet,
                        recordType: .txt,
                        useTCP: true,
                        bufferSize: 4096
                    )
                    let attributes = try TXTRecord.parseAttributes(message.value)
                    try requireValue("True", from: attributes, forExpectedKey: "success")
                } catch let error {
                    // TODO: Handle more elegantly by passing the error back up, somehow.
                    fatalError("Failed data transfer: \(error)")
                }
            }
        }
        
        // TODO: Should we have a timeout in case the server ceases to exist or something?
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER)
        
        // TODO: Waiting to send this might be adding significat delays.
        let response = try end(transmissionId, count: count)
        return response
    }
    
    public func transmit(data: NSData, responseHandler: Result<NSData> -> ()) {
        dispatch_async(TransmissionManager.queue) {
            responseHandler(Result {
                try self.transmit(data)
            })
        }
    }
}

extension TransmissionManager {
    private static let domainSafeCharacterSet: NSCharacterSet = {
        let set = NSMutableCharacterSet()
        set.formUnionWithCharacterSet(NSCharacterSet.alphanumericCharacterSet())
        set.addCharactersInString("-")
        return set
    }()

    // Will not encode data.
    internal static func package(domainSafeString data: String, underDomain domain: (sequenceNumber: Int) -> Domain) -> AnyGenerator<Domain> {
        precondition(data.rangeOfCharacterFromSet(domainSafeCharacterSet.invertedSet) == nil,
                     "String to package is not domain safe.")
        precondition(data.characters.first != "-" && data.characters.last != "-",
                     "String may not start or end with dash.")
        precondition(data.characters.count > 0, "String must have length greater than zero.")
        
        var dataIndex = data.startIndex
        var sequenceNumber = 0
        
        // Return a generator that will return the data-packed domains sequentially.
        return AnyGenerator {
            // Once we package all the data, do not return any more domains.
            guard dataIndex != data.endIndex else { return nil }
            
            // Increment sequence number with each iteration
            defer { sequenceNumber += 1 }
            
            // Get the correct parent domain.
            var domain = domain(sequenceNumber: sequenceNumber)
            
            // Record the number of levels in the domain so we can prepend before them.
            let level = domain.level
            
            // In each iteration, append a data label to the domain
            // looping while there is still data to append and space to append it
            while true {
                let nextLabelLength = min(
                    domain.maxNextLabelLength,
                    dataIndex.distanceTo(data.endIndex)
                )
                guard nextLabelLength > 0 else { break }
                
                // From the length, compute the end index
                let labelEndIndex = dataIndex.advancedBy(nextLabelLength)
                defer { dataIndex = labelEndIndex }
                
                // Prepend the component
                domain.prepend(String(data[dataIndex..<labelEndIndex]), atLevel: level)
            }
            
            return domain
        }
    }
    
    // Will encode data making it 25% longer.
    internal static func package(arbitraryData data: NSData, underDomain domain: (sequenceNumber: Int) -> Domain) -> AnyGenerator<Domain> {
        precondition(data.length > 0, "Data must have length greater than zero.")
        
        let domainSafeData = data.base64EncodedStringWithOptions([]).utf8
        return package(domainSafeString: String(domainSafeData), underDomain: domain)
    }
}