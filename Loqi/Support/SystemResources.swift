import Foundation

#if os(iOS)
import os
#endif

enum SystemResources {
    static func availableMemoryBytes() -> UInt64 {
        #if os(iOS)
        UInt64(max(0, os_proc_available_memory()))
        #else
        ProcessInfo.processInfo.physicalMemory
        #endif
    }
}
