import OpenEngine

extension EngineWebContentHostFactory {
  func webContent(_ webContent: OEWebContent, didReceiveOpenWorldMessage type: String,
                  payloadJSON: String, documentID: String) {
    let pickerAccepted = app.stores.boosts.existingEditorHost?.receivePickerMessage(webContent, type: type, payloadJSON: payloadJSON, documentID: documentID) ?? false
    #if OPEN_AUTOMATION
    // Keep a bounded automation receipt. Full payloads are never persisted.
    recordedOpenWorldMessages.append([
      "content": webContent.identifier, "type": type,
      "payloadJSON": payloadJSON, "documentID": documentID,
      "pickerAccepted": pickerAccepted,
    ])
    if recordedOpenWorldMessages.count > 64 { recordedOpenWorldMessages.removeFirst() }
    #else
    _ = pickerAccepted
    #endif
  }
}
