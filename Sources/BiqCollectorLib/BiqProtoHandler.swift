//
//  BiqProtoHandler.swift
//  BiqCollectorLib
//
//  Created by Kyle Jessup on 2018-02-14.
//

import Foundation
import PerfectCRUD
import Dispatch
#if os(Linux)
import SwiftGlibc
#endif

import BiqNetLib

public func readFeedBack(_ connection: BiqProtoConnection) -> UInt16? {
	let fd = connection.net.fd.fd
	guard fd > 0 else {
		CRUDLogging.log(.info, "Bad file descriptor")
		return nil
	}
	guard let pointer = malloc(2) else {
		CRUDLogging.log(.info, "Unable to allocate bytes")
		return nil
	}
	defer {
		free(pointer)
	}
	CRUDLogging.log(.info, "Server is pending feedback")
	let result = receive_from(fd, 2, pointer, 2)
	guard result > 0 else {
		CRUDLogging.log(.error, "feedback failure: \(result)")
		return nil
	}
	let feedback = pointer.assumingMemoryBound(to: UInt16.self).pointee
	CRUDLogging.log(.info, "feedback: \(feedback)")
	return feedback
}


public func handleBiqProtoConnection(_ connection: BiqProtoConnection) {

	connection.readReport {
		response in
		do {
      var obs = BiqObs()
      var shouldRespond = true
			var shouldWaitForFeedback = false
      if let rpt = try response() as? BiqReportWithVersion {
				let r = rpt.report
				shouldWaitForFeedback = rpt.version > biqProtoVersion2
				CRUDLogging.log(.info, "ReportV2 read: \(r), version: \(rpt.version)")
        shouldRespond = r.delegate
        obs.bixid = r.bixid
        obs.obstime = r.timestamp
        obs.charging = r.charging
        obs.firmware = r.fwVersion
        obs.wifiFirmware = r.wifiVersion
        obs.battery = r.battery
        obs.temp = min(r.temperature, r.rhtemp)
        obs.light = r.light
        obs.humidity = r.humidity
        obs.accelx = r.accelx
        obs.accely = r.accely
        obs.accelz = r.accelz
      }else if let report = try response() as? BiqReport {
        CRUDLogging.log(.info, "Report read: \(report)")
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
      } else {
        CRUDLogging.log(.error, "Unable to read report")
        return
      }

      print("obs:", obs)
			let response: BiqResponse
			do {
				let status = noError
				let responseValues = try obs.save(shouldRespond, removePushLimits: !shouldWaitForFeedback)
                // in batch mode, only the last record should broadcast
                guard shouldRespond else { return }
				DispatchQueue.global().async { obs.reportSave() }
				response = BiqResponse(version: biqProtoVersion, status: status, values: responseValues)
			} catch {
				CRUDLogging.log(.error, "Failure while saving obs data \(error). retryReportError")
				response = BiqResponse(version: biqProtoVersion, status: retryReportError, values: [])
			}
			let crcCode = try? response.crcCalc()
			connection.writeResponse(response) {
				response in
				do {
					try response()
					if shouldWaitForFeedback, let crc = crcCode, let fb = readFeedBack(connection), fb == crc {
						CRUDLogging.log(.info, "CRC matched, pushing done.")
						try? obs.cleanup()
					}
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
