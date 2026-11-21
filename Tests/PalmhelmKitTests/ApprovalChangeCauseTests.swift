import Testing
import Foundation
@testable import PalmhelmKit

// 2b：详情里的改动正文与起因；旧 Bridge 没有这两个字段时按缺省解码。
@Suite struct ApprovalChangeCauseTests {
    private let view = #"{"id":"0123456789abcdef","status":"pending","targetLabel":"bridge","attribution":"exact","toolName":"Edit","summary":"README.md","truncated":false,"createdT":1,"expiresT":600001}"#

    @Test func decodesChangeAndCause() throws {
        let json = ###"{"approval":{"view":\###(view),"body":{"change":{"path":"README.md","kind":"edit","hunks":[{"old":"## 安装（五步）","new":"## 安装（三步）","replaceAll":true}],"more":2,"truncated":true}},"cause":{"status":"ok","prompt":{"text":"把 README 的安装一节改成三步","origin":"feishu","t":1792638060658},"note":{"text":"现在的安装一节有五步。\n我把它合并成三步。","t":1792638070000,"truncated":false}}}}"###
        let d = try JSONDecoder().decode(ApprovalDetailResponse.self, from: Data(json.utf8)).approval
        let c = try #require(d.body?.change)
        #expect(c.kind == "edit" && c.path == "README.md" && c.more == 2 && c.truncated && c.hidden == nil)
        #expect(c.hunks.count == 1 && c.hunks[0].old == "## 安装（五步）" && c.hunks[0].replaceAll == true)
        let cause = try #require(d.cause)
        #expect(cause.isAvailable && cause.prompt?.origin == "feishu" && cause.note?.text.contains("\n") == true)
    }

    @Test func hiddenChangeAndUnavailableCause() throws {
        let json = ###"{"approval":{"view":\###(view),"body":{"change":{"path":"（内容已隐藏）","kind":"write","hunks":[],"more":0,"truncated":false,"hidden":true}},"cause":{"status":"unavailable"}}}"###
        let d = try JSONDecoder().decode(ApprovalDetailResponse.self, from: Data(json.utf8)).approval
        #expect(d.body?.change?.hidden == true && d.body?.change?.hunks.isEmpty == true)
        #expect(d.cause?.isAvailable == false && d.cause?.prompt == nil && d.cause?.note == nil)
    }

    @Test func oldBridgeWithoutFields() throws {
        let json = ###"{"approval":{"view":\###(view)}}"###
        let d = try JSONDecoder().decode(ApprovalDetailResponse.self, from: Data(json.utf8)).approval
        #expect(d.body == nil && d.cause == nil)
    }
}
