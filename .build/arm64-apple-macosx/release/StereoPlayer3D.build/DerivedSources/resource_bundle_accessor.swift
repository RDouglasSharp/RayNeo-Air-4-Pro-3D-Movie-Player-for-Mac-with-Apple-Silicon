import Foundation

extension Foundation.Bundle {
    static nonisolated let module: Bundle = {
        let mainPath = Bundle.main.bundleURL.appendingPathComponent("StereoPlayer3D_StereoPlayer3D.bundle").path
        let buildPath = "/Users/doug/Code/StereoPlayer3D/.build/arm64-apple-macosx/release/StereoPlayer3D_StereoPlayer3D.bundle"

        let preferredBundle = Bundle(path: mainPath)

        guard let bundle = preferredBundle ?? Bundle(path: buildPath) else {
            // Users can write a function called fatalError themselves, we should be resilient against that.
            Swift.fatalError("could not load resource bundle: from \(mainPath) or \(buildPath)")
        }

        return bundle
    }()
}