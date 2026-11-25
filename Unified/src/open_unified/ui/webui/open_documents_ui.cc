// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/ui/webui/open_documents_ui.h"

#include <utility>

#include "base/functional/bind.h"
#include "base/strings/string_util.h"
#include "base/time/time.h"
#include "open_unified/browser/open_json.h"
#include "open_unified/core/documents/document_store.h"

namespace open_unified::webui {

namespace {

// Document ids are lowercase UUIDs; anything else never reaches the file
// system (the store builds file names from ids).
bool IsDocumentId(const std::string& id) {
  return DocumentStore::IsValidDocumentId(id);
}

std::string ExportFileName(const std::string& title) {
  std::string name;
  for (char c : title) {
    name += (base::IsAsciiAlphaNumeric(c) || c == '-' || c == '_' || c == ' ')
                ? c
                : '_';
  }
  name = std::string(base::TrimWhitespaceASCII(name, base::TRIM_ALL));
  if (name.empty()) {
    name = "Easel";
  }
  if (name.size() > 80) {
    name.resize(80);
  }
  return name + ".html";
}

double NowSec() {
  return base::Time::Now().InSecondsFSinceUnixEpoch();
}

}  // namespace

OpenDocumentsUI::OpenDocumentsUI(OpenWebUIMessageHandler* handler)
    : OpenRpcDomain(handler) {}

OpenDocumentsUI::~OpenDocumentsUI() = default;

void OpenDocumentsUI::RegisterMethods() {
  auto bind = [this](void (OpenDocumentsUI::*method)(const base::DictValue&,
                                                     Reply)) {
    return base::BindRepeating(method, weak_factory_.GetWeakPtr());
  };
  Register(kEaselLoad, bind(&OpenDocumentsUI::EaselLoad));
  Register(kEaselSave, bind(&OpenDocumentsUI::EaselSave));
  Register(kEaselExportHtml, bind(&OpenDocumentsUI::EaselExportHtml));
  Register(kNoteLoad, bind(&OpenDocumentsUI::NoteLoad));
  Register(kNoteSave, bind(&OpenDocumentsUI::NoteSave));
}

void OpenDocumentsUI::EaselLoad(const base::DictValue& payload,
                                Reply reply) {
  ProfileServices* ps = service()->ProfileServicesFor(profile_id());
  if (!ps) {
    ReplyError(std::move(reply), "no such profile");
    return;
  }
  const std::string id = json::GetString(payload, "id");
  auto respond = base::BindOnce(
      [](Reply reply, EaselDocument document) {
        ReplyOk(std::move(reply),
                base::DictValue().Set("document",
                                        json::EaselToValue(document)));
      },
      std::move(reply));
  if (!IsDocumentId(id)) {
    // No id (or a bad one): a new, empty Easel.
    RunOnStore(ps->documents, base::BindOnce([](DocumentStore* store) {
                 return store->CreateEasel();
               }),
               std::move(respond));
    return;
  }
  RunOnStore(
      ps->documents,
      base::BindOnce(
          [](std::string id, DocumentStore* store) {
            return store->LoadEasel(id);
          },
          id),
      base::BindOnce(
          [](base::OnceCallback<void(EaselDocument)> respond,
             base::WeakPtr<OpenDocumentsUI> self,
             std::optional<EaselDocument> document) {
            if (document) {
              std::move(respond).Run(std::move(*document));
              return;
            }
            OpenBrowserService* service = OpenBrowserService::Get();
            ProfileServices* ps =
                service && self
                    ? service->ProfileServicesFor(self->profile_id())
                    : nullptr;
            if (!ps) {
              return;  // The page is gone; nothing to answer.
            }
            RunOnStore(ps->documents, base::BindOnce([](DocumentStore* store) {
                         return store->CreateEasel();
                       }),
                       std::move(respond));
          },
          std::move(respond), weak_factory_.GetWeakPtr()));
}

void OpenDocumentsUI::EaselSave(const base::DictValue& payload,
                                Reply reply) {
  std::optional<EaselDocument> document =
      json::EaselFromValue(payload.Find("document"));
  ProfileServices* ps = service()->ProfileServicesFor(profile_id());
  if (!document || !IsDocumentId(document->id) || !ps) {
    ReplyError(std::move(reply), "invalid easel");
    return;
  }
  document->modified_at = NowSec();
  const double modified_at = document->modified_at;
  RunOnStore(
      ps->documents,
      base::BindOnce(
          [](EaselDocument document, DocumentStore* store) {
            return store->SaveEasel(document);
          },
          std::move(*document)),
      base::BindOnce(
          [](double modified_at, Reply reply, bool ok) {
            if (!ok) {
              ReplyError(std::move(reply), "the easel could not be saved");
              return;
            }
            ReplyOk(std::move(reply), base::DictValue()
                                          .Set("ok", true)
                                          .Set("modified_at", modified_at));
          },
          modified_at, std::move(reply)));
}

void OpenDocumentsUI::EaselExportHtml(const base::DictValue& payload,
                                      Reply reply) {
  std::optional<EaselDocument> document =
      json::EaselFromValue(payload.Find("document"));
  ProfileServices* ps = service()->ProfileServicesFor(profile_id());
  if (!document || !ps) {
    ReplyError(std::move(reply), "invalid easel");
    return;
  }
  const std::string filename = ExportFileName(document->title);
  RunOnStore(
      ps->documents,
      base::BindOnce(
          [](EaselDocument document, DocumentStore* store) {
            return DocumentStore::RenderEaselStandaloneHtml(document);
          },
          std::move(*document)),
      base::BindOnce(
          [](std::string filename, Reply reply, std::string html) {
            ReplyOk(std::move(reply), base::DictValue()
                                          .Set("html", std::move(html))
                                          .Set("filename", filename));
          },
          filename, std::move(reply)));
}

void OpenDocumentsUI::NoteLoad(const base::DictValue& payload,
                               Reply reply) {
  ProfileServices* ps = service()->ProfileServicesFor(profile_id());
  if (!ps) {
    ReplyError(std::move(reply), "no such profile");
    return;
  }
  const std::string id = json::GetString(payload, "id");
  auto respond = base::BindOnce(
      [](Reply reply, NoteDocument document) {
        ReplyOk(std::move(reply),
                base::DictValue().Set("document",
                                        json::NoteToValue(document)));
      },
      std::move(reply));
  if (!IsDocumentId(id)) {
    RunOnStore(ps->documents, base::BindOnce([](DocumentStore* store) {
                 return store->CreateNote();
               }),
               std::move(respond));
    return;
  }
  RunOnStore(
      ps->documents,
      base::BindOnce(
          [](std::string id, DocumentStore* store) {
            return store->LoadNote(id);
          },
          id),
      base::BindOnce(
          [](base::OnceCallback<void(NoteDocument)> respond,
             base::WeakPtr<OpenDocumentsUI> self,
             std::optional<NoteDocument> document) {
            if (document) {
              std::move(respond).Run(std::move(*document));
              return;
            }
            OpenBrowserService* service = OpenBrowserService::Get();
            ProfileServices* ps =
                service && self
                    ? service->ProfileServicesFor(self->profile_id())
                    : nullptr;
            if (!ps) {
              return;
            }
            RunOnStore(ps->documents, base::BindOnce([](DocumentStore* store) {
                         return store->CreateNote();
                       }),
                       std::move(respond));
          },
          std::move(respond), weak_factory_.GetWeakPtr()));
}

void OpenDocumentsUI::NoteSave(const base::DictValue& payload,
                               Reply reply) {
  std::optional<NoteDocument> document =
      json::NoteFromValue(payload.Find("document"));
  ProfileServices* ps = service()->ProfileServicesFor(profile_id());
  if (!document || !IsDocumentId(document->id) || !ps) {
    ReplyError(std::move(reply), "invalid note");
    return;
  }
  document->modified_at = NowSec();
  const double modified_at = document->modified_at;
  RunOnStore(
      ps->documents,
      base::BindOnce(
          [](NoteDocument document, DocumentStore* store) {
            return store->SaveNote(document);
          },
          std::move(*document)),
      base::BindOnce(
          [](double modified_at, Reply reply, bool ok) {
            if (!ok) {
              ReplyError(std::move(reply), "the note could not be saved");
              return;
            }
            ReplyOk(std::move(reply), base::DictValue()
                                          .Set("ok", true)
                                          .Set("modified_at", modified_at));
          },
          modified_at, std::move(reply)));
}

}  // namespace open_unified::webui
