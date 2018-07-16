
import XCTest
import Foundation
import Dispatch
import PerfectNet
@testable import BiqCollectorLib

let testPort: UInt16 = 8093

class BiqCollectorTests: XCTestCase {
	
	override func setUp() {
		super.setUp()
	}
	
	func testRequestResponse() {
		guard let server = try? BiqProtoServer(port: testPort, address: "127.0.0.1") else {
			return XCTAssert(false, "Unable to bind port \(testPort)")
		}
		let client = NetTCP()
		let serverStopExpectation = self.expectation(description: "serverStop")
		let clientStopExpectation = self.expectation(description: "clientStop")
		let protoReport = BiqReport(version: biqProtoVersion,
							   status: reportStatusFlagCharging,
							   biqId: "UBIQTF1111",
							   fwVersion: "01.00.09",
							   wifiVersion: "esp40.23.01",
							   values: [BiqReportValue.temperatureOne(421),
										BiqReportValue.photometric(30),
										BiqReportValue.accelerometer(1),
										BiqReportValue.relativeHumidity(14),
										BiqReportValue.temperatureOne(422)])
		let protoResponse = BiqResponse(version: biqProtoVersion,
								   status: noError,
								   values: [BiqResponseValue.reportInterval(300),
											BiqResponseValue.updateAppFW("")])
//		
//		print("report: ")
//		let hex1 = String(validatingUTF8: try! protoReport.bytes().encode(.hex)!)!
//		print(hex1)
//		
//		print("response: ")
//		let hex2 = String(validatingUTF8: try! protoResponse.bytes().encode(.hex)!)!
//		print(hex2)
//		
		DispatchQueue.global().async {
			do {
				try server.start() {
					connection in
					connection.readReport {
						result in
						do {
							let report = try result()
							XCTAssertEqual(report, protoReport)
							connection.writeResponse(protoResponse) {
								result in
								do {
									try result()
								} catch {
									XCTAssert(false, "\(error)")
								}
								server.stop()
							}
						} catch {
							XCTAssert(false, "\(error)")
							server.stop()
						}
					}
				}
			} catch {}
			serverStopExpectation.fulfill()
		}
		
		DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
			do {
				try client.connect(address: "127.0.0.1", port: testPort, timeoutSeconds: 2.0) {
					net in
					guard let net = net else {
						XCTAssert(false, "Could not connect to server")
						server.stop()
						clientStopExpectation.fulfill()
						return
					}
					let connection = BiqProtoConnection(net)
					connection.writeReport(protoReport) {
						result in
						do {
							try result()
							connection.readResponse {
								result in
								do {
									let response = try result()
									XCTAssertEqual(response, protoResponse)
									clientStopExpectation.fulfill()
								} catch {
									XCTAssert(false, "\(error)")
									server.stop()
									clientStopExpectation.fulfill()
								}
							}
						} catch {
							XCTAssert(false, "\(error)")
							server.stop()
							clientStopExpectation.fulfill()
						}
					}
				}
			} catch {
				XCTAssert(false, "\(error)")
			}
		}
		
		self.waitForExpectations(timeout: 10000) {
			_ in
			
		}
	}

    static var allTests: [(String, (BiqCollectorTests) -> () throws -> Void)] {
        return [
			("testRequestResponse", testRequestResponse),
        ]
    }
}
