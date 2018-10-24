//
//  BiqProto.swift
//  BiqCollector
//
//  Created by Kyle Jessup on 2018-02-09.
//

import PerfectNet
import Dispatch
import PerfectCrypto
import PerfectCRUD
#if os(Linux)
import Glibc
#endif

public let biqProtoVersion: UInt8 = 1
public let biqProtoVersion2: UInt8 = 2

let biqProtoReadTimeout = 60.0
let commaByte: UInt8 = 0x2c

public let noError: UInt8 = 0x0
public let protocolError: UInt8 = 0x01
public let retryReportError: UInt8 = 0x02

public let reportStatusFlagCharging: UInt8 = 0x1

extension UInt16 {
	init(first: UInt8, second: UInt8) {
		let one = UInt16(first)
		let two = UInt16(second)
		self = (two << 8) + one
	}
	var bytes: [UInt8] {
		return [UInt8(self & 0xFF), UInt8((self >> 8) & 0xFF)]
	}
}

extension Int16 {
	init(first: UInt8, second: UInt8) {
		self.init(bitPattern: UInt16(first: first, second: second))
	}
	var bytes: [UInt8] {
		return UInt16(bitPattern: self).bytes
	}
}

public struct BiqProtoError: Error, CustomStringConvertible {
	public let description: String
	init(_ d: String) {
		description = d
		CRUDLogging.log(.error, "BiqProtoError: \(d)")
	}
}

typealias ByteGenerator = IndexingIterator<[UInt8]>

protocol BytesProvider {
	func bytes() throws -> [UInt8]
}

public enum BiqReportTag: UInt8 {
	case temperatureOne = 1
	case photometric = 2
	case relativeHumidity = 3
	case temperatureTwo = 4
	case accelerometer = 5
	case batteryVoltage = 6
}

public enum BiqReportValue {
	case temperatureOne(Int16)
	case photometric(UInt8)
	case relativeHumidity(UInt8)
	case temperatureTwo(Int16)
	case accelerometer(UInt8)
	case batteryVoltage(UInt16)
}

extension BiqReportTag {
	func reportValue(gen: inout ByteGenerator) -> BiqReportValue? {
		switch self {
		case .temperatureOne:
			guard let one = gen.next(),
				let two = gen.next() else {
					return nil
			}
			return .temperatureOne(Int16(first: one, second: two))
		case .photometric:
			guard let one = gen.next() else {
				return nil
			}
			return .photometric(one)
		case .relativeHumidity:
			guard let one = gen.next() else {
				return nil
			}
			return .relativeHumidity(one)
		case .temperatureTwo:
			guard let one = gen.next(),
				let two = gen.next() else {
					return nil
			}
			return .temperatureTwo(Int16(first: one, second: two))
		case .accelerometer:
			guard let one = gen.next() else {
				return nil
			}
			return .accelerometer(one)
		case .batteryVoltage:
			guard let one = gen.next(),
				let two = gen.next() else {
					return nil
			}
			return .batteryVoltage(UInt16(first: one, second: two))
		}
	}
}

extension BiqReportValue: BytesProvider {
	func bytes() throws -> [UInt8] {
		switch self {
		case .temperatureOne(let temp1):
			return [BiqReportTag.temperatureOne.rawValue] + temp1.bytes
		case .photometric(let photo):
			return [BiqReportTag.photometric.rawValue, photo]
		case .relativeHumidity(let rh):
			return [BiqReportTag.relativeHumidity.rawValue, rh]
		case .temperatureTwo(let temp2):
			return [BiqReportTag.temperatureTwo.rawValue] + temp2.bytes
		case .accelerometer(let accel):
			return [BiqReportTag.accelerometer.rawValue, accel]
		case .batteryVoltage(let volts):
			return [BiqReportTag.batteryVoltage.rawValue] + volts.bytes
		}
	}
}

public enum BiqResponseTag: UInt8 {
	case reportFormat = 1
	case reportInterval = 2
	case reportBufferCapacity = 3
	case temperatureThreshold = 4
	case accelerometerThreshold = 5
	case lightThreshold = 6
	case humidityThreshold = 7
	case ledColour = 8
	
	case deviceCapabilities = 9
	case updateBootFW = 252
	case updateAppFW = 254
}

extension BiqResponseTag {
	func responseValue(gen: inout ByteGenerator) -> BiqResponseValue? {
		switch self {
		case .reportFormat:
			guard let one = gen.next() else {
				return nil
			}
			return .reportFormat(one)
		case .reportInterval:
			guard let one = gen.next(),
				let two = gen.next() else {
					return nil
			}
			return .reportInterval(UInt16(first: one, second: two))
		case .reportBufferCapacity:
			guard let one = gen.next(),
				let two = gen.next() else {
					return nil
			}
			return .reportBufferCapacity(UInt16(first: one, second: two))
		case .temperatureThreshold:
			guard let one = gen.next(),
				let two = gen.next(),
				let three = gen.next(),
				let four = gen.next() else {
					return nil
			}
			return .temperatureThreshold(low: Int16(first: one, second: two), high: Int16(first: three, second: four))
		case .accelerometerThreshold:
			guard let one = gen.next(),
				let two = gen.next(),
				let three = gen.next(),
				let four = gen.next(),
				let five = gen.next(),
				let six = gen.next() else {
					return nil
			}
			return .accelerometerThreshold(x: UInt16(first: one, second: two),
										   y: UInt16(first: three, second: four),
										   z: UInt16(first: five, second: six))
		case .lightThreshold:
			guard let one = gen.next(),
				let two = gen.next() else {
					return nil
			}
			return .lightThreshold(low: one, high: two)
		case .humidityThreshold:
			guard let one = gen.next(),
				let two = gen.next() else {
					return nil
			}
			return .humidityThreshold(low: one, high: two)
		case .ledColour:
			guard let one = gen.next(),
				let two = gen.next(),
				let three = gen.next() else {
					return nil
			}
			return .ledColour(r: one, g: two, b: three)
        case .deviceCapabilities:
            guard let low = gen.next(),
                let high = gen.next() else {
                    return nil
            }
            return .deviceCapabilities(low: low, high: high)
		case .updateBootFW, .updateAppFW:
			var bytes: [UInt8] = []
			while let c = gen.next() {
				if c == 0x0 {
					guard let url = String(validatingUTF8: bytes) else {
						return nil
					}
					if self == .updateBootFW {
						return .updateBootFW(url)
					}
					return .updateAppFW(url)
				} else {
					bytes.append(c)
				}
			}
			return nil			
		}
	}
}

public enum BiqResponseValue {
	case reportFormat(UInt8)
	case reportInterval(UInt16)
	case reportBufferCapacity(UInt16)
	case temperatureThreshold(low: Int16, high: Int16)
	case accelerometerThreshold(x: UInt16, y: UInt16, z: UInt16)
	case lightThreshold(low: UInt8, high: UInt8)
	case humidityThreshold(low: UInt8, high: UInt8)
	case ledColour(r: UInt8, g: UInt8, b: UInt8)
    case deviceCapabilities(low: UInt8, high: UInt8)
	case updateBootFW(String)
	case updateAppFW(String)
}

extension BiqResponseValue: BytesProvider {
	func bytes() throws -> [UInt8] {
		switch self {
		case .reportFormat(let format):
			return [BiqResponseTag.reportFormat.rawValue, format]
		case .reportInterval(let interval):
			return [BiqResponseTag.reportInterval.rawValue] + interval.bytes
		case .reportBufferCapacity(let capacity):
			return [BiqResponseTag.reportBufferCapacity.rawValue] + capacity.bytes
		case .temperatureThreshold(let low, let high):
			return [BiqResponseTag.temperatureThreshold.rawValue] + low.bytes + high.bytes
		case .accelerometerThreshold(let x, let y, let z):
			return [BiqResponseTag.accelerometerThreshold.rawValue] + x.bytes + y.bytes + z.bytes
		case .lightThreshold(let low, let high):
			return [BiqResponseTag.lightThreshold.rawValue, low, high]
		case .humidityThreshold(let low, let high):
			return [BiqResponseTag.humidityThreshold.rawValue, low, high]
		case .ledColour(let r, let g, let b):
			return [BiqResponseTag.ledColour.rawValue, r, g, b]
        case .deviceCapabilities(let low, let high):
            return [BiqResponseTag.deviceCapabilities.rawValue, low, high]
		case .updateBootFW(_):
			return [BiqResponseTag.updateBootFW.rawValue] + [1]//Array(url.utf8) + [0]
		case .updateAppFW(_):
			return [BiqResponseTag.updateAppFW.rawValue] + [1]//Array(url.utf8) + [0]
		}
	}
}

public struct BiqReportV2 {
  // the first record in a callback array will delegate the response for alll
  public var delegate = false
  public let bixid: String
  public let timestamp: Double
  public let charging: Int
  public let fwVersion: String
  public let wifiVersion: String
  public let battery:Double
  public let temperature: Double
  public let rhtemp: Double
  public let humidity: Int
  public let light: Int
  public let accelx: Int
  public let accely: Int
  public let accelz: Int

  public enum Exception: Error {
    case InvalidEncoding
  }

  fileprivate typealias BiqRecordHeaderV2 = (clock: Int32, count: Int16, reserved: Int16)

  fileprivate typealias BiqRecordV2 = (clk: Int32,
    bat: Int16, tmp: Int16, rht: Int16, hum: Int8, lum: Int8,
    x: Int32, y: Int32, z: Int32)

  public static func parseReports(bytes: [UInt8]) throws -> [BiqReportV2] {
    let qreport = bytes.withUnsafeBytes {
      bufferPointer -> (clock: Int, records: [BiqRecordV2], id: String, efm: String, esp: String)? in
      guard let address = bufferPointer.baseAddress else { return nil }
      let header = address.bindMemory(to: BiqRecordHeaderV2.self, capacity: 1).pointee
      let clock = Int(header.clock)
      let count = Int(header.count)
      let dataPointer = address.advanced(by: MemoryLayout<BiqRecordHeaderV2>.size)
      let stringPointer = dataPointer.advanced(by: MemoryLayout<BiqRecordV2>.size * count)
      let string = String(cString: stringPointer.assumingMemoryBound(to: CChar.self))
      let contents:[String] = string.split(separator: ",").map { String($0) }
      guard count * MemoryLayout<BiqRecordV2>.size + MemoryLayout<BiqRecordHeaderV2>.size < bytes.count,
        contents.count == 3 else { return nil }
      let databuf = dataPointer.bindMemory(to: BiqRecordV2.self, capacity: count)
      let data = UnsafeBufferPointer(start: databuf, count: count)
      let records = Array(data)
      return (clock: clock, records: records, id: contents[0], efm: contents[1], esp: contents[2])
    }

    guard let q = qreport else {
      throw Exception.InvalidEncoding
    }
    let offset = Int(time(nil)) - q.clock;
    var reports: [BiqReportV2] = q.records.map { r -> BiqReportV2 in
        BiqReportV2
            .init(delegate: false, bixid: q.id,
                  timestamp: Double(offset + Int(r.clk)) * 1000,
                  charging: r.bat < 0 ? 1 : 0,
                  fwVersion: q.efm, wifiVersion: q.esp, battery: Double(abs(r.bat)) / 100.0,
                  temperature: Double(r.tmp) / 10.0, rhtemp: Double(r.rht) / 10.0,
                  humidity: Int(r.hum), light: Int(r.lum),
                  accelx: Int(r.x), accely: Int(r.y), accelz: Int(r.z))
    }
    if q.records.isEmpty {
        // make a "null" record for command forwarding
        reports.append(BiqReportV2.init(delegate: true, bixid: q.id, timestamp: 0, charging: 0, fwVersion: q.efm, wifiVersion: q.esp, battery: 0, temperature: 0, rhtemp: 0, humidity: 0, light: 0, accelx: 0, accely: 0, accelz: 0))
    } else {
        reports[0].delegate = true
    }
    return reports
  }
}

public struct BiqReport {
	public let version: UInt8
	public let status: UInt8
	public let biqId: String
	public let fwVersion: String
	public let wifiVersion: String
	public let values: [BiqReportValue]
	public init(version vr: UInt8,
				status s: UInt8,
				biqId b: String,
				fwVersion f: String,
				wifiVersion w: String,
				values va: [BiqReportValue]) {
		version = vr
		status = s
		biqId = b
		fwVersion = f
		wifiVersion = w
		values = va
	}
}

extension BiqReport: BytesProvider {
	func bytes() throws -> [UInt8] {
		let payloads1 = Array("\(biqId),\(fwVersion),\(wifiVersion)".utf8) + [0]
		let payloads2 = try values.flatMap { try $0.bytes() }
		let payloadCount = 4 + payloads1.count + payloads2.count
		guard payloadCount <= UInt16.max else {
			throw BiqProtoError("Report payload length \(payloadCount) exceeded max value \(UInt16.max).")
		}
		let reportBytes: [UInt8] = UInt16(payloadCount).bytes + [biqProtoVersion, status] + payloads1 + payloads2
		return reportBytes
	}
}

extension BiqReport: Equatable {
	public static func ==(lhs: BiqReport, rhs: BiqReport) -> Bool {
		guard lhs.version == rhs.version,
			lhs.status == rhs.status,
			lhs.biqId == rhs.biqId,
			lhs.fwVersion == rhs.fwVersion,
			lhs.wifiVersion == rhs.wifiVersion else {
				return false
		}
		for (lhsV, rhsV) in zip(lhs.values, rhs.values) {
			switch (lhsV, rhsV) {
			case (.temperatureOne(let a), .temperatureOne(let b)) where a == b:
				continue
			case (.photometric(let a), .photometric(let b)) where a == b:
				continue
			case (.relativeHumidity(let a), .relativeHumidity(let b)) where a == b:
				continue
			case (.temperatureTwo(let a), .temperatureTwo(let b)) where a == b:
				continue
			case (.accelerometer(let a), .accelerometer(let b)) where a == b:
				continue
			default:
				return false
			}
		}
		return true
	}
}

public struct BiqResponse {
	public let version: UInt8
	public let status: UInt8
	public let values: [BiqResponseValue]
	public init(version vr: UInt8,
				status s: UInt8,
				values va: [BiqResponseValue]) {
		version = vr
		status = s
		values = va
	}
}

extension BiqResponse: BytesProvider {
	func bytes() throws -> [UInt8] {
		let payloads = try values.flatMap { try $0.bytes() }
		let payloadCount = payloads.count + 4
		guard payloadCount <= UInt16.max else {
			throw BiqProtoError("Response payload length \(payloadCount) exceeded max value \(UInt16.max).")
		}
		let responseBytes: [UInt8] = UInt16(payloadCount).bytes + [biqProtoVersion, 0] + payloads
		return responseBytes
	}
}

extension BiqResponse: Equatable {
	public static func ==(lhs: BiqResponse, rhs: BiqResponse) -> Bool {
		guard lhs.version == rhs.version,
			lhs.status == rhs.status else {
				return false
		}
		for (lhsV, rhsV) in zip(lhs.values, rhs.values) {
			switch (lhsV, rhsV) {
			case (.reportFormat(let a), .reportFormat(let b)) where a == b:
				continue
			case (.reportInterval(let a), .reportInterval(let b)) where a == b:
				continue
			case (.reportBufferCapacity(let a), .reportBufferCapacity(let b)) where a == b:
				continue
			case (.temperatureThreshold(let aa, let ab), .temperatureThreshold(let ba, let bb)) where aa == ba && ab == bb:
				continue
			case (.accelerometerThreshold(let aa, let ab, let ac), .accelerometerThreshold(let ba, let bb, let bc)) where aa == ba && ab == bb && ac == bc:
				continue
			case (.lightThreshold(let aa, let ab), .lightThreshold(let ba, let bb)) where aa == ba && ab == bb:
				continue
			case (.humidityThreshold(let aa, let ab), .humidityThreshold(let ba, let bb)) where aa == ba && ab == bb:
				continue
			case (.ledColour(let aa, let ab, let ac), .ledColour(let ba, let bb, let bc)) where aa == ba && ab == bb && ac == bc:
				continue
            case (.deviceCapabilities(let aa, let ab), .deviceCapabilities(let ba, let bb)) where aa == ba && ab == bb:
                continue
			case (.updateBootFW(let a), .updateBootFW(let b)) where a == b:
				continue
			case (.updateAppFW(let a), .updateAppFW(let b)) where a == b:
				continue
			default:
				return false
			}
		}
		return true
	}
}

public typealias BiqReportGetFunc = (() throws -> Any)
public typealias BiqResponseGetFunc = (() throws -> BiqResponse)
public typealias BiqResponsePutFunc = (() throws -> ())
public typealias BiqReportPutFunc = (() throws -> ())

public struct BiqProtoConnection {
	let net: NetTCP
	public init(_ n: NetTCP) {
		net = n
	}
}

// as client funcs
public extension BiqProtoConnection {
	func readResponse(_ callback: @escaping (BiqResponseGetFunc) -> ()) {
		readResponseHeader(callback)
	}
	
	func writeReport(_ report: BiqReport, _ callback: @escaping (BiqReportPutFunc) -> ()) {
		let reportBytes: [UInt8]
		do {
			reportBytes = try report.bytes()
		} catch {
			return callback({ throw error })
		}
		net.write(bytes: reportBytes) {
			wrote in
			guard wrote == reportBytes.count else {
				return callback({throw BiqProtoError("Failed to write full report.")})
			}
			return callback({})
		}
	}
	
	private func readResponseHeader(_ callback: @escaping (BiqResponseGetFunc) -> ()) {
		net.readBytesFully(count: 4, timeoutSeconds: biqProtoReadTimeout) {
			bytes in
			guard let bytes = bytes, bytes.count == 4 else {
				return self.errorReply(code: protocolError) { callback({throw BiqProtoError("Unable to read first 4 bytes of response.")}) }
			}
			let payloadLength = Int(UInt16(first: bytes[0], second: bytes[1])) - 4
			let protocolVersion = bytes[2]
			
//			guard protocolVersion == biqProtoVersion else {
//				return self.errorReply(code: protocolError) { callback({throw BiqProtoError("Unhandled protocol version \(protocolVersion).")}) }
//			}
			
			let responseCode = bytes[3]
			self.readResponseBody(payloadLength: payloadLength,
								protocolVersion: protocolVersion,
								statusFlags: responseCode,
								callback)
		}
	}
	
	private func readResponseBody(payloadLength: Int,
								protocolVersion: UInt8,
								statusFlags: UInt8,
								_ callback: @escaping (BiqResponseGetFunc) -> ()) {
		net.readBytesFully(count: payloadLength, timeoutSeconds: biqProtoReadTimeout) {
			bytes in
			guard let bytes = bytes, bytes.count == payloadLength else {
				return self.errorReply(code: protocolError) { callback({throw BiqProtoError("Unable to read response payload.")}) }
			}
			var byteGen = bytes.makeIterator()
			var values: [BiqResponseValue] = []
			while let tag = byteGen.next() {
				guard let responseTag = BiqResponseTag(rawValue: tag) else {
					return self.errorReply(code: protocolError) { callback({throw BiqProtoError("Invalid response tag \(tag).")}) }
				}
				guard let responseValue = responseTag.responseValue(gen: &byteGen) else {
					return self.errorReply(code: protocolError) { callback({throw BiqProtoError("Invalid response value for tag \(tag).")}) }
				}
				values.append(responseValue)
			}
			let response = BiqResponse(version: protocolVersion,
									   status: statusFlags,
									   values: values)
			callback({ return response })
		}
	}
}

// as server funcs
public extension BiqProtoConnection {
	// will close the connection after sending reply package
	func errorReply(code: UInt8, _ closure: @escaping () -> ()) {
		let response = BiqResponse(version: biqProtoVersion, status: code, values: [])
		writeResponse(response) {
			reply in
			try? reply()
			self.net.shutdown()
			self.net.close()
			closure()
		}
	}
	
	func readReport(_ callback: @escaping (BiqReportGetFunc) -> ()) {
		readReportHeader(callback)
	}
	
	func writeResponse(_ response: BiqResponse, _ callback: @escaping (BiqResponsePutFunc) -> ()) {
		let responseBytes: [UInt8]
		do {
			responseBytes = try response.bytes()
		} catch {
			return callback({ throw error })
		}
		net.write(bytes: responseBytes) {
			wrote in
			guard wrote == responseBytes.count else {
				return callback({throw BiqProtoError("Failed to write full response.")})
			}
			return callback({})
		}
	}
	
	private func readReportHeader(_ callback: @escaping (BiqReportGetFunc) -> ()) {
		net.readBytesFully(count: 4, timeoutSeconds: biqProtoReadTimeout) {
			bytes in
			guard let bytes = bytes, bytes.count == 4 else {
				return self.errorReply(code: protocolError) { callback({throw BiqProtoError("Unable to read first 4 bytes of report.")}) }
			}
			let payloadLength = Int(UInt16(first: bytes[0], second: bytes[1])) - 4
			let protocolVersion = bytes[2]
			
			guard [biqProtoVersion, biqProtoVersion2].contains(protocolVersion) else {
				return self.errorReply(code: protocolError) { callback({throw BiqProtoError("Unhandled protocol version \(protocolVersion).")}) }
			}
			
			let statusFlags = bytes[3]
			self.readReportBody(payloadLength: payloadLength,
								protocolVersion: protocolVersion,
								statusFlags: statusFlags,
								callback)
		}
	}
	
	private func readReportBody(payloadLength: Int,
								protocolVersion: UInt8,
								statusFlags: UInt8,
								_ callback: @escaping (BiqReportGetFunc) -> ()) {
		net.readBytesFully(count: payloadLength, timeoutSeconds: biqProtoReadTimeout) {
			bytes in
			guard let bytes = bytes, bytes.count == payloadLength else {
				return self.errorReply(code: protocolError) { callback({throw BiqProtoError("Unable to read report payload.")}) }
			}
      if protocolVersion == biqProtoVersion2 {
          do {
            let reports = try BiqReportV2.parseReports(bytes: bytes)
            reports.forEach { report in
              callback { return report }
            }
          } catch let err {
            callback { throw err }
          }
          return
      }
			var byteGen = bytes.makeIterator()
			guard let biqId = self.stringUntil(delimiter: commaByte, gen: &byteGen),
				let fwVersion = self.stringUntil(delimiter: commaByte, gen: &byteGen),
				let wifiVersion = self.stringUntil(delimiter: 0, gen: &byteGen) else {
					return self.errorReply(code: protocolError) { callback({throw BiqProtoError("Unable to read report id and version info.")}) }
			}
			var values: [BiqReportValue] = []
			while let tag = byteGen.next() {
				guard let reportTag = BiqReportTag(rawValue: tag) else {
					return self.errorReply(code: protocolError) { callback({throw BiqProtoError("Invalid report tag \(tag).")}) }
				}
				guard let reportValue = reportTag.reportValue(gen: &byteGen) else {
					return self.errorReply(code: protocolError) { callback({throw BiqProtoError("Invalid report value for tag \(tag).")}) }
				}
				values.append(reportValue)
			}
			let report = BiqReport(version: protocolVersion,
								   status: statusFlags,
								   biqId: biqId,
								   fwVersion: fwVersion,
								   wifiVersion: wifiVersion,
								   values: values)
			callback({ return report })
		}
	}
	
	private func stringUntil(delimiter: UInt8, gen: inout ByteGenerator) -> String? {
		var bytes: [UInt8] = []
		while let byte = gen.next() {
			if byte == delimiter {
				return String(validatingUTF8: bytes)
			}
			bytes.append(byte)
		}
		return nil
	}
}

public struct BiqProtoServer {
	let net: NetTCP
	public init(port: UInt16, address: String = "0.0.0.0") throws {
		net = NetTCP()
		try net.bind(port: port, address: address)
		net.listen()
		print("Binding BiqProtoServer on \(address):\(port)")
	}
	
	// receives client connection and calls handler in new thread
	public func start(_ handler: @escaping (BiqProtoConnection) -> ()) throws {
		net.forEachAccept {
			client in
			guard let client = client else {
				return
			}
			DispatchQueue.global().async {
				handler(BiqProtoConnection(client))
			}
		}
	}
	
	public func stop() {
		net.close()
	}
}







