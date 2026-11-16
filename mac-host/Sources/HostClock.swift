import Darwin

/// The Mac's monotonic clock for everything sent to the phone (capture times, Pong, barcode):
/// `CLOCK_UPTIME_RAW` in nanoseconds, which is `mach_absolute_time` scaled, so SCK's `displayTime`
/// converts exactly.
enum HostClock {
    static func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    static func ns(fromMachTime t: UInt64) -> UInt64 { t &* timebase.numer / timebase.denom }
}
