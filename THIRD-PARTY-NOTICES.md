# Third-party notices

Jelly Shark is MIT licensed (see `LICENSE`). It bundles and links the work
listed below, which carries its own terms. Each license was read from the
upstream project at the version this repository pins — none is assumed from
convention.

## Bundled font

**Atkinson Hyperlegible Next**
Copyright 2020–2024 The Atkinson Hyperlegible Next Project Authors
<https://github.com/googlefonts/atkinson-hyperlegible-next>
SIL Open Font License, Version 1.1 — full text in
`Packages/DesignSystem/Sources/DesignSystem/Resources/Fonts/OFL.txt`

The two Atkinson Hyperlegible Next variable font files in that directory are
committed to this repository and ship inside the app bundle. They are the only
fonts redistributed here — the Fontshare / Indian Type Foundry families the
themes also use are git-ignored and must be downloaded separately, as their
EULA forbids redistribution. See `Resources/Fonts/FONTS.md`.

OFL 1.1 requires the license text to travel with the font binaries, which is
why `OFL.txt` sits beside them rather than only being referenced here.

## Swift Package Manager dependencies

Fetched at build time rather than vendored into this repository, but linked
into the shipped app. Versions are those pinned in `Package.resolved`.

**Get 2.2.1** — <https://github.com/kean/Get>
MIT License. Copyright (c) 2021–2024 Alexander Grebenyuk.

**jellyfin-sdk-swift 3.4.0** (module `JellyfinAPI`) —
<https://github.com/jellyfin/jellyfin-sdk-swift>
Mozilla Public License, Version 2.0. Copyright (c) 2026 Jellyfin & Jellyfin
Contributors. Full text: `LICENSE.md` in that repository, and
<https://mozilla.org/MPL/2.0/>

MPL 2.0 is a file-level copyleft: it reaches modifications to the SDK's own
files, not this application's separate files that merely link against it
(§1.10, §3.3). No SDK source is modified or vendored here, so the obligation is
attribution.

### Linked through jellyfin-sdk-swift

The SDK's own server discovery depends on these. Jelly Shark does not call
that code, but SwiftPM links the packages into the app all the same. Each is
Apache License, Version 2.0: <https://www.apache.org/licenses/LICENSE-2.0>

**swift-nio 2.105.0** — <https://github.com/apple/swift-nio>
Copyright (c) Apple Inc. and the SwiftNIO project authors.

**swift-nio-transport-services 1.28.0** — <https://github.com/apple/swift-nio-transport-services>
Copyright (c) Apple Inc. and the SwiftNIO project authors.

**swift-atomics 1.3.1** — <https://github.com/apple/swift-atomics>
Copyright (c) Apple Inc. and the Swift project authors.

**swift-collections 1.7.6** — <https://github.com/apple/swift-collections>
Copyright (c) Apple Inc. and the Swift project authors.

**swift-system 1.9.0** — <https://github.com/apple/swift-system>
Copyright (c) Apple Inc. and the Swift System project authors.

Apache 2.0 §4(d) requires a package's `NOTICE` file to travel with
redistributions. Of the five, only swift-nio has one; it is reproduced here
unchanged from 2.105.0:

<details>
<summary>swift-nio NOTICE.txt</summary>

```text

                            The SwiftNIO Project
                            ====================

Please visit the SwiftNIO web site for more information:

  * https://github.com/apple/swift-nio

Copyright 2017, 2018 The SwiftNIO Project

The SwiftNIO Project licenses this file to you under the Apache License,
version 2.0 (the "License"); you may not use this file except in compliance
with the License. You may obtain a copy of the License at:

  https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
License for the specific language governing permissions and limitations
under the License.

Also, please refer to each LICENSE.<component>.txt file, which is located in
the 'license' directory of the distribution file, for the license terms of the
components that this product depends on.

-------------------------------------------------------------------------------

This product is heavily influenced by Netty.

  * LICENSE (Apache License 2.0):
    * https://github.com/netty/netty/blob/4.1/LICENSE.txt
  * HOMEPAGE:
    * https://netty.io

---

This product contains NodeJS's llhttp.

  * LICENSE (MIT):
    * https://github.com/nodejs/llhttp/blob/1e1c5b43326494e97cf8244ff57475eb72a1b62c/LICENSE-MIT
  * HOMEPAGE:
    * https://github.com/nodejs/llhttp

---

This product contains "cpp_magic.h" from Thomas Nixon & Jonathan Heathcote's uSHET

  * LICENSE (MIT):
    * https://github.com/18sg/uSHET/blob/c09e0acafd86720efe42dc15c63e0cc228244c32/lib/cpp_magic.h
  * HOMEPAGE:
    * https://github.com/18sg/uSHET

---

This product contains "sha1.c" and "sha1.h" from FreeBSD (Copyright (C) 1995, 1996, 1997, and 1998 WIDE Project)

  * LICENSE (BSD-3):
    * https://opensource.org/licenses/BSD-3-Clause
  * HOMEPAGE:
    * https://github.com/freebsd/freebsd-src

---

This product contains a derivation of Fabian Fett's 'Base64.swift'.

  * LICENSE (Apache License 2.0):
    * https://github.com/swift-extras/swift-extras-base64/blob/b8af49699d59ad065b801715a5009619100245ca/LICENSE
  * HOMEPAGE:
    * https://github.com/fabianfett/swift-base64-kit

---

This product contains a derivation of "XCTest+AsyncAwait.swift" & "StructuredConcurrencyHelpers" from AsyncHTTPClient.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/swift-server/async-http-client

---

This product contains a derivation of "_TinyArray.swift" from SwiftCertificates.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/apple/swift-certificates

---

This product contains a derivation of the mocking infrastructure from Swift System.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/apple/swift-system

---

This product contains a derivation of "TokenBucket.swift" from Swift Package Manager.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/swiftlang/swift-package-manager
```

</details>

## Design tokens

`BaseColors` is the Tailwind CSS v4 palette, referenced by name and converted
from oklch. Tailwind CSS is MIT licensed (<https://github.com/tailwindlabs/tailwindcss>).
Listed for credit rather than obligation — colour values are facts, not
copyrightable expression.
