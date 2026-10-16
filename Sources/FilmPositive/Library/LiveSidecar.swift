import FilmSidecar

extension Sidecar {
    /// This sidecar with every field the app retired read as its neutral value, so a value
    /// an older build left in a file neither renders nor survives the next save, and a file
    /// without one reads and writes exactly as it is.
    ///
    /// The ONE place a retired field is dropped. `FolderSession.scan` applies it on read and
    /// `AppModel` on every write, so opening a folder rewrites nothing and the field goes
    /// the next time that frame's sidecar is written for any other reason.
    ///
    /// - The enhance layer is cut down to the app's own sliders (`EnhanceControl.live`).
    /// - The develop layer's highlight axes are read as identity. They are a
    ///   profile-building function and not a frame's edit. The shared package keeps the
    ///   field so an older build still reads its own files, and the codec writes nothing
    ///   for the identity, so the attribute leaves the file.
    var withLiveFields: Sidecar {
        var out = self
        if let e = enhance { out.enhance = EnhanceControl.live(e) }
        if var d = develop, !d.highlightAxes.isIdentity {
            d.highlightAxes = .identity
            out.develop = d
        }
        return out
    }
}
