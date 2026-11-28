import Foundation

/// 개수 제한이 있는 캐시. 가득 차면 가장 오래 쓰지 않은 항목부터 버린다(LRU).
/// 메인 스레드에서만 사용한다(스레드 안전하지 않음).
final class BoundedCache<Key: Hashable, Value> {
    private let capacity: Int
    private var storage: [Key: Value] = [:]
    /// 사용 순서 (앞 = 오래됨, 뒤 = 최근)
    private var order: [Key] = []

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    var count: Int { storage.count }

    /// 값을 읽고 '최근 사용' 으로 표시한다.
    func value(for key: Key) -> Value? {
        guard let v = storage[key] else { return nil }
        touch(key)
        return v
    }

    func contains(_ key: Key) -> Bool { storage[key] != nil }

    func set(_ value: Value, for key: Key) {
        storage[key] = value
        touch(key)
        while order.count > capacity {
            let oldest = order.removeFirst()
            storage[oldest] = nil
        }
    }

    func removeValue(for key: Key) {
        storage[key] = nil
        order.removeAll { $0 == key }
    }

    func removeAll() {
        storage.removeAll()
        order.removeAll()
    }

    private func touch(_ key: Key) {
        if let i = order.lastIndex(of: key) { order.remove(at: i) }
        order.append(key)
    }
}
