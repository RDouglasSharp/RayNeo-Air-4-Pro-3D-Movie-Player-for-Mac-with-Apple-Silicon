import Darwin

/// Write debug message to /tmp/stereo_debug.log (release build: no-op).
public func logDebug(_ message: String) {
    #if STEREO_AUTOPLAY
    if let fp = fopen("/tmp/stereo_debug.log", "a") {
        fputs(message, fp)
        fflush(fp)
        fclose(fp)
    }
    #endif
}
