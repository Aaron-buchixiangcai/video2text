import Foundation

enum WordDocumentExporter {
    static func docxData(title: String, transcript: Transcript, diarized: Bool) -> Data {
        let paragraphs = documentParagraphs(title: title, transcript: transcript, diarized: diarized)
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
        \(paragraphs)
            <w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr>
          </w:body>
        </w:document>
        """

        return ZipWriter.archive(entries: [
            .init(path: "[Content_Types].xml", data: data(contentTypes)),
            .init(path: "_rels/.rels", data: data(relationships)),
            .init(path: "word/document.xml", data: data(document)),
        ])
    }

    private static func documentParagraphs(title: String, transcript: Transcript, diarized: Bool) -> String {
        var paragraphs = [paragraph(shortTitle(title), isTitle: true)]
        let items = diarized ? transcript.coalesced().utterances : transcript.utterances
        for utterance in items {
            let label = diarized
                ? (utterance.speaker.map { "说话人\($0 + 1)：" } ?? "")
                : ""
            paragraphs.append(paragraph("[\(formatTimestamp(utterance.start))] \(label)\(utterance.text)", isTitle: false))
        }
        return paragraphs.joined(separator: "\n")
    }

    private static func paragraph(_ text: String, isTitle: Bool) -> String {
        let runStyle = isTitle ? "<w:rPr><w:b/><w:sz w:val=\"32\"/></w:rPr>" : ""
        return """
            <w:p><w:r>\(runStyle)<w:t xml:space="preserve">\(escapeXML(text))</w:t></w:r></w:p>
        """
    }

    private static func shortTitle(_ title: String) -> String {
        TitleFormatter.shortFileStem(title)
    }

    private static func escapeXML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func data(_ string: String) -> Data {
        Data(string.utf8)
    }

    private static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    </Types>
    """

    private static let relationships = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """
}
