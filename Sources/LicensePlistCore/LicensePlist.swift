import Foundation
import LoggerAPI
import RxBlocking
import RxSwift

public final class LicensePlist {
    let encoding = String.Encoding.utf8
    public init() {
        Logger.configure()
    }
    public func process(outputPath: URL? = nil,
                        cartfilePath: URL? = nil,
                        podsPath: URL? = nil,
                        gitHubToken: String? = nil) {
        Log.info("Start")

        GitHubAuthorizatoin.shared.token = gitHubToken

        let (licenses, _carthages, _) = collectLicenseInfos(cartfilePath: cartfilePath, podsPath: podsPath)

        let tm = TemplateManager.shared
        let prefix = "com.mono0926.LicensePlist"
        let licensListItems = licenses.map {
            return tm.licenseListItem.applied(["Title": $0.name,
                                               "FileName": "\(prefix)/\($0.name)"])
            }

        // TODO: refactor
        let outputRoot: URL
        if let outputPath = outputPath {
            outputRoot = outputPath
        } else {
            outputRoot = URL(fileURLWithPath: ".").appendingPathComponent("\(prefix)Output")
        }

        let fm = FileManager.default
        let plistPath = outputRoot.appendingPathComponent(prefix)
        if fm.fileExists(atPath: plistPath.path) {
            try! fm.removeItem(at: plistPath)
            Log.info("Deleted exiting plist within \(prefix)")
        }
        try! fm.createDirectory(at: plistPath, withIntermediateDirectories: true, attributes: nil)
        Log.info("Directory created: \(outputRoot)")

        let licenseListPlist = tm.licenseList.applied(["Item": licensListItems.joined(separator: "\n")])
        write(content: licenseListPlist, to: outputRoot.appendingPathComponent("\(prefix).LisenseList.plist"))


        licenses.forEach {
            write(content: tm.license.applied(["Body": $0.body]),
                  to: plistPath.appendingPathComponent("\($0.name).plist"))
        }

        Log.info("End")
        Log.info("----------Result-----------")
        Log.info("# Missing license:")
        let missing = Set(_carthages.map { $0.name }).subtracting(Set(licenses.map { $0.name }))
        if missing.isEmpty {
            Log.info("None🎉")
        }  else {
            Array(missing).sorted { $0 < $1 }.forEach { Log.warning($0) }
        }
    }

    private func collectLicenseInfos(cartfilePath: URL?, podsPath: URL?) -> ([LicenseInfo], [CarthageLicense], [CocoaPodsLicense]) {
        Log.info("Pods License parse start")
        let podsAcknowledgements = readPodsAcknowledgements(path: podsPath)
        let cocoaPodsLicenses = podsAcknowledgements.map { CocoaPodsLicense.parse($0) }.flatMap { $0 }

        Log.info("Carthage License collect start")

        var carthageLibraries = [Carthage]()
        if let cartfileContent = readCartfile(path: cartfilePath) {
            carthageLibraries = Carthage.parse(cartfileContent)
        }
        let carthageLicenses = try! Observable.merge(carthageLibraries.map { CarthageLicense.collect($0).asObservable() }).toBlocking().toArray()

        let all = Array(((cocoaPodsLicenses as [LicenseInfo]) + (carthageLicenses as [LicenseInfo]))
            .reduce([String: LicenseInfo]()) { sum, e in
                var sum = sum
                sum[e.name] = e
                return sum
            }.values
            .sorted { $0.name < $1.name })
        return (all, carthageLicenses, cocoaPodsLicenses)
    }

    private func write(content: String, to path: URL) {
        try! content.write(to: path, atomically: false, encoding: encoding)
    }

    private func read(path: URL) -> String? {
        do {
            return try String(contentsOf: path, encoding: encoding)
        } catch let e {
            Log.info(String(describing: e))
            return nil
        }
    }

    private func readCartfile(path: URL?) -> String? {
        let cartfileName = "Cartfile"
        if let path = path, path.lastPathComponent != cartfileName {
            fatalError("Invalid Cartfile name: \(path.lastPathComponent)")
        }
        let path = path ?? URL(fileURLWithPath: cartfileName)
        if let content = read(path: path.appendingPathExtension("resolved")) {
            return content
        }
        return read(path: path)
    }
    private func readPodsAcknowledgements(path: URL?) -> [String] {
        let podsDirectoryName = "Pods"
        if let path = path, path.lastPathComponent != podsDirectoryName {
            fatalError("Invalid Pods name: \(path.lastPathComponent)")
        }
        let path = (path ?? URL(fileURLWithPath: podsDirectoryName)).appendingPathComponent("Target Support Files")
        let fm = FileManager.default
        if !fm.fileExists(atPath: path.path) {
            Log.warning("not found: \(path)")
            return []
        }
        let urls = (try! fm.contentsOfDirectory(at: path, includingPropertiesForKeys: nil, options: []))
            .filter {
                var isDirectory: ObjCBool = false
                fm.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                return isDirectory.boolValue
            }
            .map { f in
                (try! fm.contentsOfDirectory(at: f, includingPropertiesForKeys: nil, options: []))
                    .filter { $0.lastPathComponent.hasSuffix("-acknowledgements.plist") }
            }.flatMap { $0 }
        urls.forEach { Log.info("Pod acknowledgements found: \($0.lastPathComponent)") }
        return urls.map { read(path: $0) }.flatMap { $0 }
    }
}
