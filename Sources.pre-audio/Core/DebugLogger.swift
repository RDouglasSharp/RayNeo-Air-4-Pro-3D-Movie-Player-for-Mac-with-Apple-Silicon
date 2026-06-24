import Darwin

/// Write debug message to /tmp/stereo_debug.log
public func logDebug(_ message: String) {
    if let fp = fopen("/tmp/stereo_debug.log", "a") {
        fputs(message, fp)
        fflush(fp)
        fclose(fp)
    }
}
