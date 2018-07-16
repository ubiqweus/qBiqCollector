//
//  BiqProtoHandler.swift
//  BiqCollectorLib
//
//  Created by Kyle Jessup on 2018-02-14.
//

import Foundation
import PerfectCRUD
import Dispatch

public func handleBiqProtoConnection(_ connection: BiqProtoConnection) {
	connection.readReport {
		response in
		do {
			let report = try response()
			CRUDLogging.log(.info, "Report read: \(report)")
			var obs = BiqObs()
			obs.obstime = Double.now
			obs.bixid = report.biqId
			obs.firmware = report.wifiVersion
			obs.wifiFirmware = report.fwVersion
			obs.charging = Int(report.status & reportStatusFlagCharging)
			for reportValue in report.values {
				switch reportValue {
				case .temperatureOne(let temp):
					if obs.temp == 0.0 {
						obs.temp = Double(temp) / 10
					}
				case .photometric(let pho):
					obs.light = Int(pho)
				case .relativeHumidity(let rh):
					obs.humidity = Int(rh)
				case .temperatureTwo(let temp2):
					obs.temp = Double(temp2) / 10
				case .accelerometer(let accel):
					let v = Int(accel)
					obs.accelx = v
					obs.accely = v
					obs.accelz = v
				case .batteryVoltage(let volts):
					obs.battery = Double(volts) / 100
				}
			}
			
			let response: BiqResponse
			do {
				let status = noError
				let responseValues = try obs.save()
				DispatchQueue.global().async { obs.reportSave() }
				response = BiqResponse(version: biqProtoVersion, status: status, values: responseValues)
			} catch {
				CRUDLogging.log(.error, "Failure while saving obs data \(error). retryReportError")
				response = BiqResponse(version: biqProtoVersion, status: retryReportError, values: [])
			}
			
			connection.writeResponse(response) {
				response in
				do {
					try response()
				} catch {
					CRUDLogging.log(.error, "\(error)")
				}
			}
		} catch {
			CRUDLogging.log(.error, "\(error)")
		}
	}
}

// milliseconds since epoch
// TODO: ditch this. use timeIntervalSince1970
private extension Double {
	static var now: Double {
		var posixTime = timeval()
		gettimeofday(&posixTime, nil)
		return Double((posixTime.tv_sec * 1000) + (Int(posixTime.tv_usec)/1000))
	}
}
