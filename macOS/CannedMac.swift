//
//  CannedMac.swift
//  macOS
//
//  Created by Kenneth Endfinger on 3/22/22.
//

import Combine
import Foundation
import SwiftUI
import Virtualization

class CannedMac: ObservableObject {
    @Published
    var state: CannedMacState = .unknown

    @Published
    var downloadCurrentProgress: Double = 0.0

    @Published
    var installerCurrentProgress: Double = 0.0

    @Published
    var error: Error?

    @Published
    var vm: VZVirtualMachine?

    var downloadProgressObserver: NSKeyValueObservation?
    var installProgressObserver: NSKeyValueObservation?

    func createVmConfiguration() async throws -> (VZVirtualMachineConfiguration, VZMacOSRestoreImage?) {
        let existingHardwareModel = try loadMacHardwareModel()

        let model: VZMacHardwareModel
        let macRestoreImage: VZMacOSRestoreImage?
        if existingHardwareModel == nil {
            state = .downloadInstaller
            let image = try await downloadLatestSupportImage()

            guard let mostFeaturefulSupportedConfiguration = image.mostFeaturefulSupportedConfiguration else {
                throw UserError(.RestoreImageBad, "Restore image did not have a supported configuration.")
            }

            model = mostFeaturefulSupportedConfiguration.hardwareModel
            try saveMacHardwareModel(mostFeaturefulSupportedConfiguration.hardwareModel)
            macRestoreImage = image
        } else {
            model = existingHardwareModel!
            macRestoreImage = nil
        }

        let configuration = VZVirtualMachineConfiguration()
        configuration.cpuCount = computeCpuCount()
        configuration.memorySize = computeMemorySize()

        let platform = VZMacPlatformConfiguration()
        platform.machineIdentifier = try loadOrCreateMachineIdentifier()
        platform.auxiliaryStorage = try loadOrCreateAuxilaryStorage(model)
        platform.hardwareModel = model
        configuration.platform = platform
        configuration.bootLoader = VZMacOSBootLoader()

        let soundDeviceConfiguration = VZVirtioSoundDeviceConfiguration()
        let inputStream = VZVirtioSoundDeviceInputStreamConfiguration()
        inputStream.source = VZHostAudioInputStreamSource()
        let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
        outputStream.sink = VZHostAudioOutputStreamSink()
        soundDeviceConfiguration.streams = [inputStream, outputStream]
        configuration.audioDevices.append(soundDeviceConfiguration)

        let diskImageAttachment = try getOrCreateDiskImage()
        let storage = VZVirtioBlockDeviceConfiguration(attachment: diskImageAttachment)
        configuration.storageDevices.append(storage)

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        configuration.networkDevices.append(network)

        let keyboard = VZUSBKeyboardConfiguration()
        configuration.keyboards.append(keyboard)

        let pointingDevice = VZUSBScreenCoordinatePointingDeviceConfiguration()
        configuration.pointingDevices.append(pointingDevice)

        let memoryBalloon = VZVirtioTraditionalMemoryBalloonDeviceConfiguration()
        configuration.memoryBalloonDevices.append(memoryBalloon)

        let gpu = VZMacGraphicsDeviceConfiguration()
        let display = VZMacGraphicsDisplayConfiguration(
            widthInPixels: 1920,
            heightInPixels: 1080,
            pixelsPerInch: 80
        )
        gpu.displays.append(display)
        configuration.graphicsDevices.append(gpu)

        try configuration.validate()
        return (configuration, macRestoreImage)
    }

    @MainActor
    func bootVirtualMachine() async throws {
        let (configuration, macRestoreImage) = try await createVmConfiguration()
        let vm = VZVirtualMachine(configuration: configuration, queue: DispatchQueue.main)

        if let macRestoreImage = macRestoreImage {
            let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: macRestoreImage.url)
            installProgressObserver = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) { _, change in
                DispatchQueue.main.async {
                    if let value = change.newValue {
                        self.installerCurrentProgress = value
                    }
                }
            }
            DispatchQueue.main.async {
                self.state = .installingMacOS
            }
            try await installer.install()
            while vm.state != .stopped {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }

        DispatchQueue.main.async {
            self.state = .bootVirtualMachine
            self.vm = vm
        }
        try await vm.start()
    }

    func loadMacHardwareModel() throws -> VZMacHardwareModel? {
        let applicationSupportDirectoryUrl = try FileUtilities.getApplicationSupportDirectory()
        let hardwareModelUrl = applicationSupportDirectoryUrl.appendingPathComponent("machw.bin")

        if FileManager.default.fileExists(atPath: hardwareModelUrl.path) {
            let data = try Data(contentsOf: hardwareModelUrl)
            return VZMacHardwareModel(dataRepresentation: data)
        }
        return nil
    }

    func saveMacHardwareModel(_ model: VZMacHardwareModel) throws {
        let applicationSupportDirectoryUrl = try FileUtilities.getApplicationSupportDirectory()
        let hardwareModelUrl = applicationSupportDirectoryUrl.appendingPathComponent("machw.bin")
        try model.dataRepresentation.write(to: hardwareModelUrl)
    }

    func downloadLatestSupportImage() async throws -> VZMacOSRestoreImage {
        let applicationSupportDirectoryUrl = try FileUtilities.getApplicationSupportDirectory()
        let restoreIpswFileUrl = applicationSupportDirectoryUrl.appendingPathComponent("restore.ipsw")
        if FileManager.default.fileExists(atPath: restoreIpswFileUrl.path) {
            return try await VZMacOSRestoreImage.image(from: restoreIpswFileUrl)
        }

        let image = try await VZMacOSRestoreImage.latestSupported
        let future: Future<URL?, Error> = Future { promise in
            let task = URLSession.shared.downloadTask(with: image.url) { url, _, error in
                if let error = error {
                    promise(.failure(error))
                    return
                }
                promise(.success(url))
            }

            self.downloadProgressObserver = task.progress.observe(\.fractionCompleted, options: [.initial, .new]) { _, change in
                if let value = change.newValue {
                    DispatchQueue.main.async {
                        self.downloadCurrentProgress = value
                    }
                }
            }

            DispatchQueue.main.async {
                self.state = .downloadInstaller
            }
            task.resume()
        }

        let temporaryFileUrl = try await future.value

        guard let temporaryFileUrl = temporaryFileUrl else {
            throw UserError(.DownloadFailed, "Download of installer failed.")
        }

        try FileManager.default.moveItem(at: temporaryFileUrl, to: restoreIpswFileUrl)

        return try await VZMacOSRestoreImage.image(from: restoreIpswFileUrl)
    }

    func loadOrCreateAuxilaryStorage(_ model: VZMacHardwareModel) throws -> VZMacAuxiliaryStorage {
        let applicationSupportDirectoryUrl = try FileUtilities.getApplicationSupportDirectory()
        let auxilaryStorageUrl = applicationSupportDirectoryUrl.appendingPathComponent("macaux.bin")

        if FileManager.default.fileExists(atPath: auxilaryStorageUrl.path) {
            return VZMacAuxiliaryStorage(contentsOf: auxilaryStorageUrl)
        } else {
            return try VZMacAuxiliaryStorage(creatingStorageAt: auxilaryStorageUrl, hardwareModel: model)
        }
    }

    func loadOrCreateMachineIdentifier() throws -> VZMacMachineIdentifier {
        let applicationSupportDirectoryUrl = try FileUtilities.getApplicationSupportDirectory()
        let macIdentifierUrl = applicationSupportDirectoryUrl.appendingPathComponent("macid.bin")

        if FileManager.default.fileExists(atPath: macIdentifierUrl.path) {
            let data = try Data(contentsOf: macIdentifierUrl)
            return VZMacMachineIdentifier(dataRepresentation: data)!
        } else {
            let identifier = VZMacMachineIdentifier()
            let data = identifier.dataRepresentation
            try data.write(to: macIdentifierUrl)
            return identifier
        }
    }

    func getOrCreateDiskImage() throws -> VZDiskImageStorageDeviceAttachment {
        let applicationSupportDirectoryUrl = try FileUtilities.getApplicationSupportDirectory()
        let diskImageUrl = applicationSupportDirectoryUrl.appendingPathComponent("disk.img")

        if FileManager.default.fileExists(atPath: diskImageUrl.path) {
            return try VZDiskImageStorageDeviceAttachment(url: diskImageUrl, readOnly: false)
        } else {
            var diskSpaceToUse = Int64(128 * 1024 * 1024 * 1024)
            if try FileUtilities.diskSpaceAvailable() < diskSpaceToUse {
                diskSpaceToUse = 64 * 1024 * 1024 * 1024
            }
            try FileUtilities.createSparseImage(diskImageUrl, size: diskSpaceToUse)
            return try VZDiskImageStorageDeviceAttachment(url: diskImageUrl, readOnly: false)
        }
    }

    func computeMemorySize() -> UInt64 {
        var memorySize = (4 * 1024 * 1024 * 1024) as UInt64
        memorySize = max(memorySize, VZVirtualMachineConfiguration.minimumAllowedMemorySize)
        memorySize = min(memorySize, VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        return memorySize
    }

    func computeCpuCount() -> Int {
        let totalAvailableCPUs = ProcessInfo.processInfo.processorCount

        var virtualCPUCount = totalAvailableCPUs <= 1 ? 1 : totalAvailableCPUs - 1
        virtualCPUCount = max(virtualCPUCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        virtualCPUCount = min(virtualCPUCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount)

        return virtualCPUCount
    }

    func setCurrentError(_ error: Error) {
        state = .error
        self.error = error
    }
}

enum CannedMacState {
    case unknown
    case error
    case downloadInstaller
    case installingMacOS
    case bootVirtualMachine
}
