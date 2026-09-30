import os

enum Signposts {
    static let subsystem = "hibari"
    static let layout = OSSignposter(subsystem: subsystem, category: "Layout")
    static let render = OSSignposter(subsystem: subsystem, category: "Render")
    static let image = OSSignposter(subsystem: subsystem, category: "Image")
    static let cell = OSSignposter(subsystem: subsystem, category: "Cell")
}
