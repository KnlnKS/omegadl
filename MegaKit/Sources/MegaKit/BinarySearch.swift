extension Collection {
    /// The first index whose element satisfies `belongsInSecondPartition`, for a collection already
    /// partitioned by it (every failing element before every passing one).
    public func partitioningIndex(where belongsInSecondPartition: (Element) -> Bool) -> Index {
        var low = startIndex
        var count = distance(from: startIndex, to: endIndex)
        while count > 0 {
            let half = count / 2
            let middle = index(low, offsetBy: half)
            if belongsInSecondPartition(self[middle]) {
                count = half
            } else {
                low = index(after: middle)
                count -= half + 1
            }
        }
        return low
    }
}
