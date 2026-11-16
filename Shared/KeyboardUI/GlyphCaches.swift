// iOS (CoreText) keeps the picture of every emoji it draws, in caches of its own. In a keyboard
// they're never emptied in time: iOS closes a keyboard that goes over its memory allowance long
// before it would ask those caches to shrink. CoreText keeps the pictures (CGImages) in NSCaches,
// so Trail notes every NSCache that is given a picture, and the emoji panel empties them (see
// EmojiPanel.trimIfGrown). This is the "track and clear" approach from Mohamed Salah's write-up
// "From 2014 to Now: Fixing CoreText Emoji Glyphs Memory Retention on iOS".

import Foundation
import CoreGraphics
import ObjectiveC

enum GlyphCaches {
    private static let lock = NSLock()
    /// Held weakly: a cache that goes away drops out by itself.
    private static let caches = NSHashTable<AnyObject>.weakObjects()
    private static var installed = false

    /// Starts noting the caches (once per process; main thread). If NSCache isn't as expected,
    /// nothing changes.
    static func install() {
        guard !installed else { return }
        installed = true
        guard let cls = NSClassFromString("NSCache") else { return }
        hook(cls)
        hookWithCost(cls)
    }

    private static func hook(_ cls: AnyClass) {
        let sel = NSSelectorFromString("setObject:forKey:")
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        typealias SetFn = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Void
        let original = unsafeBitCast(method_getImplementation(m), to: SetFn.self)
        let block: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> Void = { cache, obj, key in
            GlyphCaches.note(cache, obj)
            original(cache, sel, obj, key)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    private static func hookWithCost(_ cls: AnyClass) {
        let sel = NSSelectorFromString("setObject:forKey:cost:")
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        typealias SetFn = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, UInt) -> Void
        let original = unsafeBitCast(method_getImplementation(m), to: SetFn.self)
        let block: @convention(block) (AnyObject, AnyObject?, AnyObject?, UInt) -> Void = { cache, obj, key, cost in
            GlyphCaches.note(cache, obj)
            original(cache, sel, obj, key, cost)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    /// Any thread: remembers a cache that was given a picture.
    private static func note(_ cache: AnyObject, _ obj: AnyObject?) {
        guard let obj = obj, CFGetTypeID(obj) == CGImage.typeID else { return }
        lock.lock()
        caches.add(cache)
        lock.unlock()
    }

    /// Empties the caches that hold pictures and hands the freed memory back to iOS. Pictures on
    /// screen stay; ones drawn later are made again.
    static func clear() {
        lock.lock()
        let all = caches.allObjects
        lock.unlock()
        for c in all { (c as? NSCache<AnyObject, AnyObject>)?.removeAllObjects() }
        _ = malloc_zone_pressure_relief(nil, 0)
    }
}
