import Darwin
import Synchronization

/// Append-only storage at a fixed address, backed by a large anonymous memory reservation.
///
/// The reservation is virtual: pages only cost memory once they are touched. That gives the
/// scanner what it wants from a growable array without the drawbacks: scanning threads can
/// claim slots with a single atomic add, nothing is ever copied to grow, and readers can hold
/// pointers across appends.
final class Arena<Element: BitwiseCopyable>: @unchecked Sendable {
    let base: UnsafeMutablePointer<Element>
    let capacity: Int
    private let reservedBytes: Int
    private let used = Atomic<Int>(0)

    init?(capacity: Int) {
        let bytes = capacity * MemoryLayout<Element>.stride
        let mapping = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NORESERVE, -1, 0)
        guard let mapping, mapping != MAP_FAILED else { return nil }
        self.base = mapping.bindMemory(to: Element.self, capacity: capacity)
        self.capacity = capacity
        self.reservedBytes = bytes
    }

    deinit {
        munmap(base, reservedBytes)
    }

    var count: Int {
        min(used.load(ordering: .acquiring), capacity)
    }

    /// Claims `n` consecutive slots and returns the index of the first, or nil once the
    /// reservation is exhausted.
    func allocate(_ n: Int) -> Int? {
        let start = used.add(n, ordering: .relaxed).oldValue
        return start + n <= capacity ? start : nil
    }
}
