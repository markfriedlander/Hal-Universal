//
//  About.swift
//  Hal Universal
//
//  A shared "About" surface for the studio (this file is intentionally near-
//  identical across apps; only the PER-APP DATA at the bottom differs).
//
//  Two things live here, deliberately separated:
//
//    1. The SHARED PART — a generic `AboutView` and the vocabulary it needs
//       (`OpenSourceLicense`, `Acknowledgement`) plus the canonical MIT and
//       Apache-2.0 license bodies. Identical in every studio app.
//
//    2. The PER-APP DATA — one extension (`AboutView.hal`) and one list
//       (`halAcknowledgements`) supplying Hal's identity and the open-source
//       components that ship inside Hal's binary. This is the only part an app
//       rewrites.
//
//  Why this screen exists: MIT and Apache-2.0 let us use their code freely on
//  one condition — when we ship that code inside our binary (which is what
//  compiling a dependency into the app is), we must carry its copyright notice
//  and license text along with it. An App Store binary is a sealed bundle, so an
//  in-app screen is the standard, honest way to meet that duty. This is ONLY for
//  code that ships in the binary; models the user downloads at runtime are never
//  redistributed by us and are surfaced separately, at download time (see the
//  model-license sheet in ModelCatalogService / the download flow).
//

// ==== LEGO START: 60 About (Open-Source Licenses & Acknowledgements) ====

import SwiftUI

// MARK: - Shared vocabulary

/// A permissive open-source license, named honestly and carrying its own full
/// text. We ship only permissive licenses; nothing here is copyleft.
enum OpenSourceLicense: String {
    case mit = "MIT License"
    case apache2 = "Apache License 2.0"

    var displayName: String { rawValue }

    /// The full license body, shown verbatim in the detail view. For MIT the
    /// per-component copyright line is shown separately (above this text),
    /// because every MIT project shares this same permission text but has its
    /// own copyright holder.
    var body: String {
        switch self {
        case .mit: return Self.mitBody
        case .apache2: return Self.apache2Body
        }
    }
}

/// One piece of open-source software that ships inside the app binary.
///
/// `notice` carries an Apache-2.0 NOTICE file's contents where the project ships
/// one — Apache §4 requires reproducing it. MIT components leave it nil.
struct Acknowledgement: Identifiable {
    var id: String { name }
    let name: String
    let license: OpenSourceLicense
    let copyright: String
    let url: String?
    var notice: String? = nil
}

// MARK: - The shared view

/// The studio's About screen. Generic: it takes an app's identity and its list
/// of acknowledgements and renders the same screen everywhere. Reads the version
/// and build straight from the bundle so it can never drift from the real app.
struct AboutView: View {
    let appName: String
    let tagline: String
    let ownLicense: String
    let ownCopyright: String
    let sourceURL: String?
    let acknowledgements: [Acknowledgement]

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    /// Grouped by license so identical terms sit together (all the MIT projects,
    /// then all the Apache ones), each group in the order the app declared them.
    private var groups: [(license: OpenSourceLicense, items: [Acknowledgement])] {
        let order: [OpenSourceLicense] = [.mit, .apache2]
        return order.compactMap { lic in
            let items = acknowledgements.filter { $0.license == lic }
            return items.isEmpty ? nil : (lic, items)
        }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(appName)
                        .font(.title2).fontWeight(.semibold)
                    Text(tagline)
                        .font(.subheadline).italic()
                        .foregroundStyle(.secondary)
                    Text("Version \(version) (\(build))")
                        .font(.caption).foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .padding(.top, 2)
                }
                .padding(.vertical, 4)
            }

            Section {
                LabeledContent("License", value: ownLicense)
                LabeledContent("Copyright", value: ownCopyright)
                if let sourceURL, let url = URL(string: sourceURL) {
                    Link(destination: url) {
                        HStack {
                            Text("Source code")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                        }
                    }
                }
            } header: {
                Text("This app")
            } footer: {
                Text("\(appName) is free and open source. You can read every line.")
            }

            ForEach(groups, id: \.license) { group in
                Section {
                    ForEach(group.items) { ack in
                        NavigationLink {
                            AcknowledgementDetail(ack: ack)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ack.name)
                                    .font(.subheadline)
                                Text(ack.copyright)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text(group.license.displayName)
                }
            }
        }
        .navigationTitle("About \(appName)")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The full terms for one component: its copyright, an optional NOTICE, and the
/// verbatim license body. Nothing paraphrased — the point is to reproduce, not
/// to summarize.
private struct AcknowledgementDetail: View {
    let ack: Acknowledgement

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ack.name)
                        .font(.title3).fontWeight(.semibold)
                    Text(ack.license.displayName)
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(ack.copyright)
                        .font(.footnote).foregroundStyle(.secondary)
                }

                if let urlString = ack.url, let url = URL(string: urlString) {
                    Link(destination: url) {
                        HStack {
                            Image(systemName: "link")
                            Text(urlString)
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.caption)
                        }
                        .font(.footnote)
                    }
                }

                if let notice = ack.notice {
                    Divider()
                    Text("NOTICE")
                        .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                    Text(notice)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }

                Divider()
                Text(ack.license.body)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
        }
        .navigationTitle(ack.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Canonical license bodies

extension OpenSourceLicense {
    /// The MIT permission text, without a copyright line — each component's own
    /// copyright is shown above it in the detail view.
    static let mitBody = """
    Permission is hereby granted, free of charge, to any person obtaining a copy \
    of this software and associated documentation files (the "Software"), to deal \
    in the Software without restriction, including without limitation the rights \
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
    copies of the Software, and to permit persons to whom the Software is \
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all \
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
    SOFTWARE.
    """

    /// Apache License 2.0, reproduced in full (Apache §4 requires shipping a copy
    /// of the License with the work).
    static let apache2Body = """
    Apache License
    Version 2.0, January 2004
    http://www.apache.org/licenses/

    TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

    1. Definitions.

    "License" shall mean the terms and conditions for use, reproduction, and \
    distribution as defined by Sections 1 through 9 of this document.

    "Licensor" shall mean the copyright owner or entity authorized by the \
    copyright owner that is granting the License.

    "Legal Entity" shall mean the union of the acting entity and all other \
    entities that control, are controlled by, or are under common control with \
    that entity. For the purposes of this definition, "control" means (i) the \
    power, direct or indirect, to cause the direction or management of such \
    entity, whether by contract or otherwise, or (ii) ownership of fifty percent \
    (50%) or more of the outstanding shares, or (iii) beneficial ownership of \
    such entity.

    "You" (or "Your") shall mean an individual or Legal Entity exercising \
    permissions granted by this License.

    "Source" form shall mean the preferred form for making modifications, \
    including but not limited to software source code, documentation source, and \
    configuration files.

    "Object" form shall mean any form resulting from mechanical transformation or \
    translation of a Source form, including but not limited to compiled object \
    code, generated documentation, and conversions to other media types.

    "Work" shall mean the work of authorship, whether in Source or Object form, \
    made available under the License, as indicated by a copyright notice that is \
    included in or attached to the work (an example is provided in the Appendix \
    below).

    "Derivative Works" shall mean any work, whether in Source or Object form, \
    that is based on (or derived from) the Work and for which the editorial \
    revisions, annotations, elaborations, or other modifications represent, as a \
    whole, an original work of authorship. For the purposes of this License, \
    Derivative Works shall not include works that remain separable from, or \
    merely link (or bind by name) to the interfaces of, the Work and Derivative \
    Works thereof.

    "Contribution" shall mean any work of authorship, including the original \
    version of the Work and any modifications or additions to that Work or \
    Derivative Works thereof, that is intentionally submitted to Licensor for \
    inclusion in the Work by the copyright owner or by an individual or Legal \
    Entity authorized to submit on behalf of the copyright owner. For the \
    purposes of this definition, "submitted" means any form of electronic, \
    verbal, or written communication sent to the Licensor or its \
    representatives, including but not limited to communication on electronic \
    mailing lists, source code control systems, and issue tracking systems that \
    are managed by, or on behalf of, the Licensor for the purpose of discussing \
    and improving the Work, but excluding communication that is conspicuously \
    marked or otherwise designated in writing by the copyright owner as "Not a \
    Contribution."

    "Contributor" shall mean Licensor and any individual or Legal Entity on \
    behalf of whom a Contribution has been received by Licensor and subsequently \
    incorporated within the Work.

    2. Grant of Copyright License. Subject to the terms and conditions of this \
    License, each Contributor hereby grants to You a perpetual, worldwide, \
    non-exclusive, no-charge, royalty-free, irrevocable copyright license to \
    reproduce, prepare Derivative Works of, publicly display, publicly perform, \
    sublicense, and distribute the Work and such Derivative Works in Source or \
    Object form.

    3. Grant of Patent License. Subject to the terms and conditions of this \
    License, each Contributor hereby grants to You a perpetual, worldwide, \
    non-exclusive, no-charge, royalty-free, irrevocable (except as stated in this \
    section) patent license to make, have made, use, offer to sell, sell, \
    import, and otherwise transfer the Work, where such license applies only to \
    those patent claims licensable by such Contributor that are necessarily \
    infringed by their Contribution(s) alone or by combination of their \
    Contribution(s) with the Work to which such Contribution(s) was submitted. \
    If You institute patent litigation against any entity (including a \
    cross-claim or counterclaim in a lawsuit) alleging that the Work or a \
    Contribution incorporated within the Work constitutes direct or contributory \
    patent infringement, then any patent licenses granted to You under this \
    License for that Work shall terminate as of the date such litigation is \
    filed.

    4. Redistribution. You may reproduce and distribute copies of the Work or \
    Derivative Works thereof in any medium, with or without modifications, and in \
    Source or Object form, provided that You meet the following conditions:

    (a) You must give any other recipients of the Work or Derivative Works a copy \
    of this License; and

    (b) You must cause any modified files to carry prominent notices stating that \
    You changed the files; and

    (c) You must retain, in the Source form of any Derivative Works that You \
    distribute, all copyright, patent, trademark, and attribution notices from \
    the Source form of the Work, excluding those notices that do not pertain to \
    any part of the Derivative Works; and

    (d) If the Work includes a "NOTICE" text file as part of its distribution, \
    then any Derivative Works that You distribute must include a readable copy of \
    the attribution notices contained within such NOTICE file, excluding those \
    notices that do not pertain to any part of the Derivative Works.

    You may add Your own copyright statement to Your modifications and may \
    provide additional or different license terms and conditions for use, \
    reproduction, or distribution of Your modifications, or for any such \
    Derivative Works as a whole, provided Your use, reproduction, and \
    distribution of the Work otherwise complies with the conditions stated in \
    this License.

    5. Submission of Contributions. Unless You explicitly state otherwise, any \
    Contribution intentionally submitted for inclusion in the Work by You to the \
    Licensor shall be under the terms and conditions of this License, without any \
    additional terms or conditions. Notwithstanding the above, nothing herein \
    shall supersede or modify the terms of any separate license agreement you may \
    have executed with Licensor regarding such Contributions.

    6. Trademarks. This License does not grant permission to use the trade names, \
    trademarks, service marks, or product names of the Licensor, except as \
    required for reasonable and customary use in describing the origin of the \
    Work and reproducing the content of the NOTICE file.

    7. Disclaimer of Warranty. Unless required by applicable law or agreed to in \
    writing, Licensor provides the Work (and each Contributor provides its \
    Contributions) on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY \
    KIND, either express or implied, including, without limitation, any \
    warranties or conditions of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or \
    FITNESS FOR A PARTICULAR PURPOSE. You are solely responsible for determining \
    the appropriateness of using or redistributing the Work and assume any risks \
    associated with Your exercise of permissions under this License.

    8. Limitation of Liability. In no event and under no legal theory, whether in \
    tort (including negligence), contract, or otherwise, unless required by \
    applicable law (such as deliberate and grossly negligent acts) or agreed to \
    in writing, shall any Contributor be liable to You for damages, including any \
    direct, indirect, special, incidental, or consequential damages of any \
    character arising as a result of this License or out of the use or inability \
    to use the Work (including but not limited to damages for loss of goodwill, \
    work stoppage, computer failure or malfunction, or any and all other \
    commercial damages or losses), even if such Contributor has been advised of \
    the possibility of such damages.

    9. Accepting Warranty or Additional Liability. While redistributing the Work \
    or Derivative Works thereof, You may choose to offer, and charge a fee for, \
    acceptance of support, warranty, indemnity, or other liability obligations \
    and/or rights consistent with this License. However, in accepting such \
    obligations, You may act only on Your own behalf and on Your sole \
    responsibility, not on behalf of any other Contributor, and only if You agree \
    to indemnify, defend, and hold each Contributor harmless for any liability \
    incurred by, or claims asserted against, such Contributor by reason of your \
    accepting any such warranty or additional liability.

    END OF TERMS AND CONDITIONS
    """
}

// ============================================================================
// PER-APP DATA — the only part that differs between studio apps.
// ============================================================================

extension AboutView {
    /// Hal's About screen. To adopt in another app: copy everything above this
    /// mark unchanged, then write your own factory and list from your app's
    /// verified dependency inventory.
    static var hal: AboutView {
        AboutView(
            appName: "Hal Universal",
            tagline: "Transparency isn't a feature. It's the architecture.",
            ownLicense: "MIT License",
            ownCopyright: "© 2026 Mark Friedlander",
            sourceURL: "https://github.com/markfriedlander/Hal-Universal",
            acknowledgements: halAcknowledgements
        )
    }
}

/// Everything that ships inside Hal's binary. Verified 2026-07-18 by reading each
/// dependency's own LICENSE/NOTICE file on disk (in SourcePackages/checkouts) —
/// nothing asserted from memory. The models the user downloads at runtime (Qwen,
/// Gemma, Llama, Dolphin, Ternary Bonsai, embedders) are NOT here: we never
/// redistribute them, and they are surfaced at download time via the
/// model-license sheet instead.
private let halAcknowledgements: [Acknowledgement] = [
    // — MIT —
    Acknowledgement(name: "MLX Swift", license: .mit,
                    copyright: "Copyright (c) 2023 ml-explore",
                    url: "https://github.com/ml-explore/mlx-swift"),
    Acknowledgement(name: "MLX Swift LM", license: .mit,
                    copyright: "Copyright (c) 2024 ml-explore",
                    url: "https://github.com/ml-explore/mlx-swift-lm"),
    Acknowledgement(name: "EventSource", license: .mit,
                    copyright: "Copyright 2025 Mattt",
                    url: "https://github.com/mattt/EventSource"),
    Acknowledgement(name: "yyjson", license: .mit,
                    copyright: "Copyright (c) 2020 YaoYuan",
                    url: "https://github.com/ibireme/yyjson"),
    Acknowledgement(name: "swift-embeddings", license: .mit,
                    copyright: "Copyright (c) 2024 Jan Krukowski",
                    url: "https://github.com/jkrukowski/swift-embeddings"),
    Acknowledgement(name: "swift-safetensors", license: .mit,
                    copyright: "Copyright (c) 2024 Jan Krukowski",
                    url: "https://github.com/jkrukowski/swift-safetensors"),
    Acknowledgement(name: "swift-sentencepiece", license: .mit,
                    copyright: "Copyright (c) 2024 Jan Krukowski",
                    url: "https://github.com/jkrukowski/swift-sentencepiece"),

    // — Apache-2.0 —
    Acknowledgement(name: "swift-transformers", license: .apache2,
                    copyright: "Copyright 2022 Hugging Face SAS",
                    url: "https://github.com/huggingface/swift-transformers"),
    Acknowledgement(name: "swift-huggingface", license: .apache2,
                    copyright: "Copyright 2025 Hugging Face SAS",
                    url: "https://github.com/huggingface/swift-huggingface"),
    Acknowledgement(name: "swift-jinja", license: .apache2,
                    copyright: "Copyright 2022 Hugging Face SAS",
                    url: "https://github.com/huggingface/swift-jinja"),
    Acknowledgement(name: "SwiftNIO", license: .apache2,
                    copyright: "Copyright 2017, 2018 The SwiftNIO Project",
                    url: "https://github.com/apple/swift-nio",
                    notice: """
                    The SwiftNIO Project
                    Copyright 2017, 2018 The SwiftNIO Project
                    https://github.com/apple/swift-nio
                    """),
    Acknowledgement(name: "Swift Crypto", license: .apache2,
                    copyright: "Copyright 2019 The SwiftCrypto Project",
                    url: "https://github.com/apple/swift-crypto",
                    notice: """
                    The SwiftCrypto Project
                    Copyright 2019 The SwiftCrypto Project
                    https://github.com/apple/swift-crypto
                    """),
    Acknowledgement(name: "SwiftASN1", license: .apache2,
                    copyright: "Copyright 2022 The SwiftASN1 Project",
                    url: "https://github.com/apple/swift-asn1",
                    notice: """
                    The SwiftASN1 Project
                    Copyright 2022 The SwiftASN1 Project
                    https://github.com/apple/swift-asn1
                    """),
    Acknowledgement(name: "Swift Atomics", license: .apache2,
                    copyright: "Copyright the Swift project authors",
                    url: "https://github.com/apple/swift-atomics"),
    Acknowledgement(name: "Swift Collections", license: .apache2,
                    copyright: "Copyright the Swift project authors",
                    url: "https://github.com/apple/swift-collections"),
    Acknowledgement(name: "Swift Numerics", license: .apache2,
                    copyright: "Copyright the Swift project authors",
                    url: "https://github.com/apple/swift-numerics"),
    Acknowledgement(name: "Swift System", license: .apache2,
                    copyright: "Copyright the Swift project authors",
                    url: "https://github.com/apple/swift-system"),
    Acknowledgement(name: "Swift Argument Parser", license: .apache2,
                    copyright: "Copyright the Swift project authors",
                    url: "https://github.com/apple/swift-argument-parser"),
    Acknowledgement(name: "SwiftSyntax", license: .apache2,
                    copyright: "Copyright the Swift project authors",
                    url: "https://github.com/swiftlang/swift-syntax"),
]

// ==== LEGO END: 60 About (Open-Source Licenses & Acknowledgements) ====
