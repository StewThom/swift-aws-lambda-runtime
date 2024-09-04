//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftAWSLambdaRuntime open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftAWSLambdaRuntime project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftAWSLambdaRuntime project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging
import NIOCore
import NIOPosix
import XCTest

@testable import AWSLambdaRuntimeCore

func runLambda<Handler: SimpleLambdaHandler>(behavior: LambdaServerBehavior, handlerType: Handler.Type) throws {
    try runLambda(behavior: behavior, handlerProvider: CodableSimpleLambdaHandler<Handler>.makeHandler(context:))
}

func runLambda<Handler: LambdaHandler>(behavior: LambdaServerBehavior, handlerType: Handler.Type) throws {
    try runLambda(behavior: behavior, handlerProvider: CodableLambdaHandler<Handler>.makeHandler(context:))
}

func runLambda<Handler: EventLoopLambdaHandler>(behavior: LambdaServerBehavior, handlerType: Handler.Type) throws {
    try runLambda(behavior: behavior, handlerProvider: CodableEventLoopLambdaHandler<Handler>.makeHandler(context:))
}

func runLambda<Handler: EventLoopLambdaHandler>(
    behavior: LambdaServerBehavior,
    handlerProvider: @escaping (LambdaInitializationContext) -> EventLoopFuture<Handler>
) throws {
    try runLambda(
        behavior: behavior,
        handlerProvider: { context in
            handlerProvider(context).map {
                CodableEventLoopLambdaHandler(handler: $0, allocator: context.allocator)
            }
        }
    )
}

func runLambda<Handler: EventLoopLambdaHandler>(
    behavior: LambdaServerBehavior,
    handlerProvider: @escaping (LambdaInitializationContext) async throws -> Handler
) throws {
    try runLambda(
        behavior: behavior,
        handlerProvider: { context in
            let handler = try await handlerProvider(context)
            return CodableEventLoopLambdaHandler(handler: handler, allocator: context.allocator)
        }
    )
}

func runLambda<Handler: ByteBufferLambdaHandler>(
    behavior: LambdaServerBehavior,
    handlerProvider: @escaping (LambdaInitializationContext) async throws -> Handler
) throws {
    let eventLoopGroup = NIOSingletons.posixEventLoopGroup.next()
    try runLambda(
        behavior: behavior,
        handlerProvider: { context in
            let promise = eventLoopGroup.next().makePromise(of: Handler.self)
            promise.completeWithTask {
                try await handlerProvider(context)
            }
            return promise.futureResult
        }
    )
}

func runLambda(
    behavior: LambdaServerBehavior,
    handlerProvider: @escaping (LambdaInitializationContext) -> EventLoopFuture<some ByteBufferLambdaHandler>
) throws {
    let eventLoopGroup = NIOSingletons.posixEventLoopGroup.next()
    let logger = Logger(label: "TestLogger")
    let server = MockLambdaServer(behavior: behavior, port: 0)
    let port = try server.start().wait()
    let configuration = LambdaConfiguration(
        runtimeEngine: .init(address: "127.0.0.1:\(port)", requestTimeout: .milliseconds(100))
    )
    let terminator = LambdaTerminator()
    let runner = LambdaRunner(eventLoop: eventLoopGroup.next(), configuration: configuration)
    defer { XCTAssertNoThrow(try server.stop().wait()) }
    try runner.initialize(handlerProvider: handlerProvider, logger: logger, terminator: terminator).flatMap { handler in
        runner.run(handler: handler, logger: logger)
    }.wait()
}

func assertLambdaRuntimeResult(
    _ result: Result<Int, Error>,
    shouldHaveRun: Int = 0,
    shouldFailWithError: Error? = nil,
    file: StaticString = #file,
    line: UInt = #line
) {
    switch result {
    case .success where shouldFailWithError != nil:
        XCTFail("should fail with \(shouldFailWithError!)", file: file, line: line)
    case .success(let count) where shouldFailWithError == nil:
        XCTAssertEqual(shouldHaveRun, count, "should have run \(shouldHaveRun) times", file: file, line: line)
    case .failure(let error) where shouldFailWithError == nil:
        XCTFail("should succeed, but failed with \(error)", file: file, line: line)
    case .failure(let error) where shouldFailWithError != nil:
        XCTAssertEqual(
            String(describing: shouldFailWithError!),
            String(describing: error),
            "expected error to mactch",
            file: file,
            line: line
        )
    default:
        XCTFail("invalid state")
    }
}

struct TestError: Error, Equatable, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

extension Date {
    var millisSinceEpoch: Int64 {
        Int64(self.timeIntervalSince1970 * 1000)
    }
}

extension LambdaRuntimeError: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        // technically incorrect, but good enough for our tests
        String(describing: lhs) == String(describing: rhs)
    }
}

extension LambdaTerminator.TerminationError: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.underlying.count == rhs.underlying.count else {
            return false
        }
        // technically incorrect, but good enough for our tests
        return String(describing: lhs) == String(describing: rhs)
    }
}

// for backward compatibility in tests
extension LambdaRunner {
    func initialize<Handler: ByteBufferLambdaHandler>(
        handlerType: Handler.Type,
        logger: Logger,
        terminator: LambdaTerminator
    ) -> EventLoopFuture<Handler> {
        self.initialize(handlerProvider: handlerType.makeHandler(context:), logger: logger, terminator: terminator)
    }
}
