import Foundation

/// 内核配置补丁：高级设置里写一段 YAML，合并进 Proxi 生成的配置。
///
/// 合并方式：
/// - `rules` 里的规则排在所有规则前面（最先匹配）。
/// - `proxies`、`proxy-groups`、`listeners` 里的项目追加进去；和已有的同名时替换它（可以改「节点」这些组的写法）。
/// - 其余的映射（`dns`、`sniffer`、`proxy-providers`、`rule-providers`、`hosts`……）逐层合并，补丁里写了的键覆盖原来的。
/// - 其余的值直接替换。
/// - API 地址、密钥和代理端口由 Proxi 管理，补丁里写了也不用。
enum ConfigPatch {
    static let protectedKeys: Set<String> = ["external-controller", "external-controller-tls", "external-controller-unix", "external-controller-pipe", "secret", "mixed-port"]
    static let prependedLists: Set<String> = ["rules"]
    static let namedLists: Set<String> = ["proxies", "proxy-groups", "listeners"]

    struct Result: Equatable {
        var text: String
        var notes: [String]
    }

    /// 把补丁合并进生成的配置文本。补丁不是 YAML 映射时抛错。
    static func apply(_ patch: String, to base: String) throws -> Result {
        let patchNode = try YAMLParser.parse(patch)
        guard case .mapping = patchNode else {
            if patchNode.isNull { return Result(text: base, notes: []) }
            throw YAMLError(line: 0, message: L("补丁要是「键: 值」形式的 YAML"))
        }
        let baseNode = try YAMLParser.parse(base)
        let (merged, notes) = merge(base: baseNode, patch: patchNode)
        return Result(text: YAMLWriter.write(merged), notes: notes)
    }

    /// 顶层的合并。
    static func merge(base: YAMLNode, patch: YAMLNode) -> (YAMLNode, [String]) {
        guard case .mapping(let basePairs) = base, case .mapping(let patchPairs) = patch else { return (base, []) }
        var result = YAMLNode.mapping(basePairs)
        var notes: [String] = []
        for pair in patchPairs {
            if protectedKeys.contains(pair.key) {
                notes.append(L("补丁里的 %@ 没有使用：它由 Proxi 管理", pair.key))
                continue
            }
            let existing = result[pair.key]
            if prependedLists.contains(pair.key), let items = pair.value.array {
                result.set(pair.key, .sequence(items + (existing?.array ?? [])))
            } else if namedLists.contains(pair.key), let items = pair.value.array {
                result.set(pair.key, .sequence(mergeNamed(existing?.array ?? [], items)))
            } else if let existing {
                result.set(pair.key, deepMerge(existing, pair.value))
            } else {
                result.set(pair.key, pair.value)
            }
        }
        return (result, notes)
    }

    /// 映射逐层合并；其余的用补丁里的。
    static func deepMerge(_ base: YAMLNode, _ patch: YAMLNode) -> YAMLNode {
        guard case .mapping(let basePairs) = base, case .mapping(let patchPairs) = patch else { return patch }
        var result = YAMLNode.mapping(basePairs)
        for pair in patchPairs {
            if let existing = result[pair.key] {
                result.set(pair.key, deepMerge(existing, pair.value))
            } else {
                result.set(pair.key, pair.value)
            }
        }
        return result
    }

    /// 按 name 合并列表：同名的替换，新的追加在后面。
    static func mergeNamed(_ base: [YAMLNode], _ patch: [YAMLNode]) -> [YAMLNode] {
        var result = base
        for item in patch {
            if let name = item["name"]?.string, let index = result.firstIndex(where: { $0["name"]?.string == name }) {
                result[index] = item
            } else {
                result.append(item)
            }
        }
        return result
    }
}
