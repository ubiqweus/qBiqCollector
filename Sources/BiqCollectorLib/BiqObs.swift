//
//  BixObs.swift
//  BiqCollector
//
//  Created by Jonathan Guthrie on 2016-12-05.
//
//

import struct Foundation.UUID
import PerfectCloudFormation
import PerfectCrypto
import PerfectCRUD
import PerfectPostgreSQL
import SwiftCodables
import PerfectNotifications
import SAuthCodables
import Foundation
import PerfectThread

let obsAddMsgKey = "obs-add"
extension AliasBrief: TableNameProvider {
	public static var tableName = Alias.CRUDTableName
}


public struct Config: Codable {
	public struct Notifications: Codable {
		let keyName: String
		let keyId: String
		let teamId: String
		let topic: String
		let production: Bool
	}
	public let notifications: Notifications?

	public static let name = "qbiq-limits"
	public static var configuration: Config? = nil
	public static func get(path: String) throws -> Config {
		let url = URL.init(fileURLWithPath: path)
		let data = try Data.init(contentsOf: url, options: Data.ReadingOptions.uncached)
		return try JSONDecoder().decode(Config.self, from: data)
	}

	public static func setup(configurationFilePath: String, keyPath: String) throws {
		let conf = try Config.get(path: configurationFilePath)
		guard let n = conf.notifications else { fatalError("configuration \(configurationFilePath) failed") }
		NotificationPusher.addConfigurationAPNS(
			name: Config.name,
			production: n.production,
			keyId: n.keyId,
			teamId: n.teamId,
			privateKeyPath: keyPath)
		Config.configuration = conf
	}
}

public struct BiqObs: Codable, TableNameProvider {
	public static var tableName = "obs"
	public static var reportSink: CloudFormation.ElastiCacheInstance?
	public static var databaseInfo: CloudFormation.RDSInstance? {
		didSet {
			guard let dbInfo = databaseInfo else {
				return
			}
			do {
				let db = try Database<PostgresDatabaseConfiguration>(
					configuration: .init(database: "biq",
										 host: dbInfo.hostName,
										 port: dbInfo.hostPort,
										 username: dbInfo.userName,
										 password: dbInfo.password))
				try db.create(BiqDeviceFirmware.self, primaryKey: \.version, policy: .reconcileTable)
				try db.create(BiqDevicePushLimit.self, policy: .reconcileTable)
					.index(unique: true, \.deviceId, \.limitType)
			} catch {
				CRUDLogging.log(.error, "\(error)")
			}
		}
	}
	public static var timeouts: [String: time_t] = [:]
	// the db table is set to permit nulls for these, but the codables model does not have null properties and I think adding nulls would break it
	// so fix it when you can
	public var bixid: String = ""
	public var obstime: Double = 0
	public var charging: Int = 0
	public var firmware: String = ""
	public var wifiFirmware: String?
	public var battery: Double = 0
	public var temp: Double = 0
	public var light: Int = 0
	public var humidity: Int = 0
	public var accelx: Int = 0
	public var accely: Int = 0
	public var accelz: Int = 0
}

extension BiqObs {

	func cleanup () throws {
		guard let dbInfo = BiqObs.databaseInfo else {
			throw PostgresCRUDError("Database info not set.")
		}
		let db = try Database<PostgresDatabaseConfiguration>(
			configuration: .init(database: "biq",
													 host: dbInfo.hostName,
													 port: dbInfo.hostPort,
													 username: dbInfo.userName,
													 password: dbInfo.password))

		try db.transaction {
			let table = db.table(BiqDevicePushLimit.self)
			let whereClause = table.where(\BiqDevicePushLimit.deviceId == bixid)
			try whereClause.delete()
		}
	}

	func getLimitPercentagePair(value: Float) -> (UInt8, UInt8){
		let ushort = UInt16(value)
		var upper = UInt8((ushort & 0xFF00) >> 8)
		var lower = UInt8(ushort & 0x00FF)
		if lower > 100 { lower = 100 }
		if upper > 100 { upper = 100 }
		if lower > upper {
			let mid = upper
			upper = lower
			lower = mid
		}
		return (lower, upper)
	}

	func save(_ delegate: Bool = true, removePushLimits: Bool = true) throws -> [BiqResponseValue] {
		guard let dbInfo = BiqObs.databaseInfo else {
			throw PostgresCRUDError("Database info not set.")
		}
		let db = try Database<PostgresDatabaseConfiguration>(
			configuration: .init(database: "biq",
								 host: dbInfo.hostName,
								 port: dbInfo.hostPort,
								 username: dbInfo.userName,
								 password: dbInfo.password))
        
        // for null record, just skip it for command forwarding purposes.
        if abs(obstime) > 1e-6 {
            try db.table(BiqObs.self).insert(self)
        }
        
        // in a batch mode, only the last record should trigger the return codes
        guard delegate else {
            return []
        }
		// gather push limits
		let pushLimits: [BiqDevicePushLimit] = try db.transaction {
			let table = db.table(BiqDevicePushLimit.self)
			let whereClause = table.where(\BiqDevicePushLimit.deviceId == bixid)
			let all = try whereClause.select().map {$0}
			if !all.isEmpty && removePushLimits {
				try whereClause.delete()
			}
			return all
		}
		var tempHigh: Float?
		var tempLow: Float?
    var sampleRate: UInt8?
		// convert into response values
		var values: [BiqResponseValue] = pushLimits.compactMap {
			limit in
			guard let type = limit.type else {
				return nil
			}
			switch type.rawValue {
			case BiqDeviceLimitType.tempHigh.rawValue:
				tempHigh = limit.limitValue
				return nil
			case BiqDeviceLimitType.tempLow.rawValue:
				tempLow = limit.limitValue
				return nil
			case BiqDeviceLimitType.humidityLevel.rawValue:
				let pair = getLimitPercentagePair(value: limit.limitValue)
				return .humidityThreshold(low: pair.0, high: pair.1)
			case BiqDeviceLimitType.lightLevel.rawValue:
				let pair = getLimitPercentagePair(value: limit.limitValue)
				return .lightThreshold(low: pair.0, high: pair.1)
			case BiqDeviceLimitType.movementLevel.rawValue:
				let strValue = limit.limitValueString ?? "0000,0000,0000"
				let value: [UInt16] = strValue.split(separator: ",")
					.map { String($0) }.map { UInt16($0, radix: 16) ?? 0}
				CRUDLogging.log(.info, "Parsed Motional Settings \(strValue) \(value)")
				return .accelerometerThreshold(x: value[0], y: value[1], z: value[2])
			case BiqDeviceLimitType.colour.rawValue:
				guard let colour = Int(limit.limitValueString ?? "4C96FC", radix: 16) else {
					return nil
				}
				let b = UInt8(colour & 0xff), g = UInt8((colour >> 8) & 0xff), r = UInt8((colour >> 16) & 0xff)
				return .ledColour(r: r, g: g, b: b)
			case BiqDeviceLimitType.interval.rawValue:
				let interval = UInt16(limit.limitValue)
				return .reportInterval(interval)
      case BiqDeviceLimitType.reportBufferCapacity.rawValue:
        sampleRate = UInt8(limit.limitValue)
        return nil
      case BiqDeviceLimitType.reportFormat.rawValue:
        return .reportFormat(UInt8(limit.limitValue))
			default:
				return nil
			}
		}
		
        let db2 = try Database<PostgresDatabaseConfiguration>(
            configuration: .init(database: "qbiq_devices2",
                                 host: dbInfo.hostName,
                                 port: dbInfo.hostPort,
                                 username: dbInfo.userName,
                                 password: dbInfo.password))
        if let deviceType = (try db2.transaction { () -> Int? in
            let table = db2.table(BiqDevice.self)
            let whereClause = table.where(\BiqDevice.id == bixid)
            let all = try whereClause.select().map { $0.flags ?? 0 }
            return all.first
            }){

            let dev = UInt8(deviceType)
            let sample = sampleRate ?? 0 // use 0 if no sampleRate is applicable
            values.append(.deviceCapabilities(low: dev, high: sample))
        }
		if let tempHigh = tempHigh, let tempLow = tempLow {
			values.append(contentsOf: [.temperatureThreshold(low: Int16(tempLow * 10), high: Int16(tempHigh * 10))])
		}
		
		// firmware pushes always go last
		if let nextEFM = try BiqDeviceFirmware.nextVersion(of: .efm, from: firmware, db) {
			CRUDLogging.log(.info, "Sending want EFM update to \(bixid)@\(firmware)->\(nextEFM).")
			values.append(.updateBootFW(""))
		} else if let wifiFirmware = self.wifiFirmware,
			let nextESP = try BiqDeviceFirmware.nextVersion(of: .esp, from: wifiFirmware, db) {
			CRUDLogging.log(.info, "Sending want ESP update to \(bixid)@\(wifiFirmware)->\(nextESP).")
			values.append(.updateAppFW(""))
		} else {
			CRUDLogging.log(.info, "No firmware for \(bixid)@esp:\(wifiFirmware ?? "")/efm:\(firmware).")
		}
		if !values.isEmpty {
			CRUDLogging.log(.info, "Sending response values \(values)")
		}
		return values
	}
}

extension BiqObs {

	enum NoteType {
		case checkIn
		case motion
		case temperature(Double, Bool)
		case humidity(Int)
		case brightness(Int)
	}

	private func isObsMoved() -> Bool {
		let counter = accelx & 0xFFFF
		let xy = accely
		let z = accelz & 0xFFFF
		let moved = xy != 0 || z != 0
		CRUDLogging.log(.info, "motional data: \(counter), \(xy), \(z), \(moved), conclusion: \(counter > 0 && moved)")
		return counter > 0 && moved
	}

	private func getThresholds(value: Float) -> (low:Int, high:Int) {
		let v = UInt16(value)
		var low = Int(v & 0x00FF)
		var high = Int((v & 0xFF00) >> 8)
		if low < 0 { low = 0 } else if low > 100 { low = 100 }
		if high < 0 { high = 0 } else if high > 100 { high = 100 }
		if low > high {
			let mid = high
			high = low
			low = mid
		}
		return (low: low, high: high)
	}

	private func isObsOverHumid(limits: [BiqDeviceLimit] = []) -> Bool {
		guard let lim = (limits.filter { $0.type == .humidityLevel }.first) else {
			CRUDLogging.log(.info, "no humidity threshold found")
			return false
		}
		let threshold = getThresholds(value: lim.limitValue)
		CRUDLogging.log(.info, "humidity: \(humidity) in range: [\(threshold.low), \(threshold.high)]")
		return humidity < threshold.low || humidity > threshold.high
	}

	private func isObsOverBright(limits: [BiqDeviceLimit] = []) -> Bool {
		guard let lim = (limits.filter { $0.type == .lightLevel }.first) else {
			CRUDLogging.log(.info, "no brightness threshold found")
			return false
		}
		let threshold = getThresholds(value: lim.limitValue)
		CRUDLogging.log(.info, "brightness: \(light) in range: [\(threshold.low), \(threshold.high)]")
		return light < threshold.low || light > threshold.high
	}

	private func isObsOverTemperature(limits: [BiqDeviceLimit] = []) -> Bool {
		let lim: [(Float, BiqDeviceLimitType)] = limits.map { limitaion -> (Float, BiqDeviceLimitType) in
			return (limitaion.limitValue, BiqDeviceLimitType.init(rawValue: limitaion.limitType))
		}
		CRUDLogging.log(.info, "temperature limits: \(lim.count)")
		guard let low = (lim.filter { $0.1 == .tempLow}).first,
			let high = (lim.filter { $0.1 == .tempHigh}).first else {
				CRUDLogging.log(.error, "no temperature threshold found")
				return false
		}
		CRUDLogging.log(.info, "temperature: \(temp) in range:[\(low.0), \(high.0)]")
		return temp < Double(low.0) || temp > Double(high.0)
	}

	private func getNoteType() throws -> NoteType? {
		guard let dbInfo = BiqObs.databaseInfo else {
			return nil
		}
		let db = try Database<PostgresDatabaseConfiguration>(
			configuration: .init(database: "qbiq_devices2",
													 host: dbInfo.hostName,
													 port: dbInfo.hostPort,
													 username: dbInfo.userName,
													 password: dbInfo.password))
		guard let device = try db.table(BiqDevice.self).where(\BiqDevice.id == bixid).first(),
			let owner = device.ownerId else { return nil }
		let limits:[BiqDeviceLimit] = try db.table(BiqDeviceLimit.self)
			.where(\BiqDeviceLimit.deviceId == bixid && \BiqDeviceLimit.userId == owner)
			.select().map { $0 }
		CRUDLogging.log(.info, "note type inspecting: \(limits.count) threshold found for owner \(owner.uuidString)")
		if isObsMoved() { return .motion }
		if isObsOverBright(limits: limits) { return .brightness(light) }
		if isObsOverHumid(limits: limits) { return .humidity(humidity) }
		if isObsOverTemperature(limits: limits) {
			let lim: [(Float, BiqDeviceLimitType)] = limits.map { limitaion -> (Float, BiqDeviceLimitType) in
				return (limitaion.limitValue, BiqDeviceLimitType.init(rawValue: limitaion.limitType))
			}
			let scale = lim.filter { $0.1 == .tempScale }.first
			let farhrenheit: Bool
			if let farh = scale, farh.0 > 0 {
				farhrenheit = true
			} else {
				farhrenheit = false
			}
			return .temperature(temp, farhrenheit)
		}
		return .checkIn
	}

	private func sendBiqNotification(config: Config.Notifications, userDevices: [String], title: String,
																	 biqName: String, deviceId: String, biqColour: String,
																	 batteryLevel: Double, charging: Bool, isOwner: Bool,
																	 formattedValue: String, alertMessage: String) {
		let promise: Promise<Bool> = Promise {
			p in
			NotificationPusher(apnsTopic: config.topic).pushAPNS(
				configurationName: Config.name,
				deviceTokens: userDevices,
				notificationItems: [
					.customPayload("qbiq.name", biqName),
					.customPayload("qbiq.id",deviceId),
					.customPayload("qbiq.colour", biqColour),
					.customPayload("qbiq.battery", batteryLevel),
					.customPayload("qbiq.charging", charging),
					.customPayload("qbiq.shared", !isOwner),
					.customPayload("qbiq.value", formattedValue),
					.mutableContent,
					.category("qbiq.alert"),
					.threadId(deviceId),
					.alertTitle(title),
					.alertBody(alertMessage)]) {
						responses in
						p.set(true)
						guard responses.count == userDevices.count else {
							return CRUDLogging.log(.error, "sendBiqNotification: mismatching responses vs userDevices count.")
						}
						for (response, device) in zip(responses, userDevices) {
							if case .ok = response.status {
								CRUDLogging.log(.info, "sendBiqNotification: success for device \(device)")
							} else {
								CRUDLogging.log(.error, "sendBiqNotification: \(response.stringBody) failed for device \(device)")
							}
						}
			}
		}
		guard let b = try? promise.wait(), b == true else {
			CRUDLogging.log(.error, "Failed promise while waiting for notifications.")
			return
		}
	}

	func reportSave() throws {

		guard let dbInfo = BiqObs.databaseInfo, let noteType = try getNoteType(), let note = Config.configuration?.notifications else {
			CRUDLogging.log(.error, "note type is invalid")
			return
		}
		let db = try Database<PostgresDatabaseConfiguration>(
			configuration: .init(database: "qbiq_devices2",
													 host: dbInfo.hostName,
													 port: dbInfo.hostPort,
													 username: dbInfo.userName,
													 password: dbInfo.password))
		let deviceId = bixid
		guard let device = try db.table(BiqDevice.self).where(\BiqDevice.id == deviceId).first() else { return }
		CRUDLogging.log(.info, "checking device \(deviceId)")
		let biqName: String
		if device.name.count > 0 {
			biqName = device.name
		} else {
			let last = deviceId.endIndex
			let begin = deviceId.index(last, offsetBy: -6)
			biqName = String(deviceId[begin..<last])
		}

		CRUDLogging.log(.info, "device name = \(biqName)")
		let title: String
		let alert: String
		switch noteType {
		case .temperature(let temp, let farhrenheit):
			let tempScale = farhrenheit ? TemperatureScale.fahrenheit : TemperatureScale.celsius
			let tempString = tempScale.formatC(temp)
			title = "Temperature Alert"
			alert = "\(biqName): temperature is reaching \(tempString)"
		case .humidity(let humidity):
			title = "Humidity Alert"
			alert = "\(biqName): humidity is reaching \(humidity)%"
		case .brightness(let lightLevel):
			title = "Brightness Alert"
			alert = "\(biqName): light level is reaching \(lightLevel)%"
		case .motion:
			title = "Movement Alert"
			alert = "\(biqName) has been moved over \(accelx & 0xFFFF) times"
		default:
			// ignore check-in
			CRUDLogging.log(.info, "ignore regular check-in")
			return
		}

		let adb = try Database<PostgresDatabaseConfiguration>(
			configuration: .init(database: "qbiq_user_auth2",
													 host: dbInfo.hostName,
													 port: dbInfo.hostPort,
													 username: dbInfo.userName,
													 password: dbInfo.password))
		try adb.sql("INSERT INTO chatlog(topic, poster, content) VALUES($1, $1, $2)",
								bindings:  [("$1", .string(deviceId)), ("$2", .string(alert))])

		let triggers: [BiqDeviceLimit] = try db.table(BiqDeviceLimit.self)
			.where(\BiqDeviceLimit.deviceId == deviceId &&
				\BiqDeviceLimit.limitType == BiqDeviceLimitType.notifications.rawValue &&
				\BiqDeviceLimit.limitValue != 0).select().map { $0 }
		CRUDLogging.log(.info, "\(triggers.count) triggers found")
		let limitsTable = db.table(BiqDeviceLimit.self)
		for limit in triggers {
			let aliasTable = adb.table(AliasBrief.self)
			let mobileTable = adb.table(MobileDeviceId.self)
			let userIds = try aliasTable.where(\AliasBrief.account == limit.userId).select().map { $0.address }
			if userIds.isEmpty { continue }
			CRUDLogging.log(.error, "\(userIds.count) users found")
			let userDevices = try mobileTable.where(\MobileDeviceId.aliasId ~ userIds).select().map { $0.deviceId }
			let timeoutKey = "\(limit.userId)/\(deviceId)"
			let now = time(nil)
			let seconds = time_t(limit.limitValue)

			if let timeout = BiqObs.timeouts[timeoutKey] {
				if now > (timeout + seconds) {
					BiqObs.timeouts[timeoutKey] = now
					CRUDLogging.log(.info, "timeout expired. sending notification now")
				} else {
					// skip this notification
					CRUDLogging.log(.info, "sendBiqNotification: skip \(timeoutKey)")
					continue;
				}
			} else {
				CRUDLogging.log(.info, "No timeout found. sending notification now")
				BiqObs.timeouts[timeoutKey] = now
			}
			do {
				let biqColour: String
				if let colour = try limitsTable
					.where(\BiqDeviceLimit.deviceId == deviceId &&
						\BiqDeviceLimit.userId == limit.userId &&
						\BiqDeviceLimit.limitType == BiqDeviceLimitType.colour.rawValue).first()?.limitValueString {
					biqColour = colour
				} else {
					biqColour = "4c96fc"
				}

				let isOwner = device.ownerId == limit.userId
				self.sendBiqNotification(config: note, userDevices: userDevices, title: title, biqName: biqName, deviceId: deviceId, biqColour: biqColour,
																 batteryLevel: battery, charging: charging != 0, isOwner: isOwner,
																 formattedValue: "\(humidity)%", alertMessage: alert)
			}
		}
		CRUDLogging.log(.info, "notification completed")
		return
	}
}
