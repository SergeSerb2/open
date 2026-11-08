// Copyright (c) 2026 The Open Authors. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of Google Inc. nor the name Chromium Embedded
// Framework nor the names of its contributors may be used to endorse
// or promote products derived from this software without specific prior
// written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
// ---------------------------------------------------------------------------
//
// Open fork API (docs/plans/media-pip.md §6, EM-1b, EM-2, EM-3, EM-5; EM-4
// declared). The contents of this file must follow a specific format in order
// to support the CEF translator tool. See the translator.README.txt file in
// the tools directory for more information.
//

#ifndef CEF_INCLUDE_CEF_MEDIA_CONTROLLER_H_
#define CEF_INCLUDE_CEF_MEDIA_CONTROLLER_H_
#pragma once

#include "include/cef_api_hash.h"
#include "include/cef_base.h"
#include "include/cef_browser.h"
#include "include/cef_values.h"

#if CEF_API_ADDED(CEF_EXPERIMENTAL)

class CefPictureInPictureWindow;

///
/// Receives the media state of one browser: Chromium's media session, its
/// players, the audible state and Picture in Picture. The methods of this
/// class are called on the browser process UI thread.
///
/*--cef(source=client,added=experimental)--*/
class CefMediaControllerHandler : public virtual CefBaseRefCounted {
 public:
  ///
  /// The browser started or stopped producing sound (Chromium's tab audio
  /// indicator signal: media elements, Web Audio and WebRTC, in background
  /// browsers too). Called for every change.
  ///
  /*--cef()--*/
  virtual void OnAudibleChanged(CefRefPtr<CefBrowser> browser, bool audible) {}

  ///
  /// The value of CefMediaController::GetState changed. Called at most once
  /// per message-loop turn, and only for a real change: a position update
  /// that only continues the playback clock is not a change.
  ///
  /*--cef()--*/
  virtual void OnMediaStateChanged(CefRefPtr<CefBrowser> browser) {}

  ///
  /// Return true to show Picture in Picture of |browser| in the embedder's
  /// window (OnPictureInPictureOpened) instead of Chromium's: video Picture in
  /// Picture (EM-4) and, for Chrome style browsers, Document Picture in
  /// Picture (EM-7).
  ///
  /*--cef()--*/
  virtual bool ShouldHostPictureInPicture(CefRefPtr<CefBrowser> browser) {
    return false;
  }

  ///
  /// Picture in Picture of |browser| opened in |window| (a video, or a
  /// document: CefPictureInPictureWindow::GetState "kind"). Synchronous,
  /// inside Chromium's session start: call
  /// CefPictureInPictureWindow::SetWindowFrame before returning, and do not
  /// close the window from inside this call.
  ///
  /*--cef()--*/
  virtual void OnPictureInPictureOpened(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefPictureInPictureWindow> window) {}

  ///
  /// The value of CefPictureInPictureWindow::GetState changed.
  ///
  /*--cef()--*/
  virtual void OnPictureInPictureChanged(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefPictureInPictureWindow> window) {}

  ///
  /// The Picture in Picture session of |window| ended (closed, source
  /// navigated, crashed or destroyed). |window| is invalid afterwards.
  ///
  /*--cef()--*/
  virtual void OnPictureInPictureClosed(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefPictureInPictureWindow> window) {}
};

///
/// The media of one browser (all its frames): Chromium's media session, its
/// players, the audible state, a tab volume and video Picture in Picture.
/// Works for Chrome style and Alloy style browsers. The methods of this class
/// must be called on the browser process UI thread.
///
/*--cef(source=library,added=experimental)--*/
class CefMediaController : public virtual CefBaseRefCounted {
 public:
  ///
  /// Returns the media controller of |browser|, creating it if needed, and
  /// sets its handler (replacing any previous one; nullptr removes it).
  /// Returns nullptr if |browser| has no page (closing).
  ///
  /*--cef(optional_param=handler)--*/
  static CefRefPtr<CefMediaController> GetForBrowser(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefMediaControllerHandler> handler);

  ///
  /// Returns true until the browser's page goes away.
  ///
  /*--cef()--*/
  virtual bool IsValid() = 0;

  ///
  /// Returns true if the browser is producing sound now.
  ///
  /*--cef()--*/
  virtual bool IsAudible() = 0;

  ///
  /// Returns the media state as a dictionary. Keys: "active" (bool: a player
  /// has played, or the media session is not inactive; all other keys only
  /// matter when true), "playbackState" ("none", "paused", "playing"),
  /// "sessionState" ("active", "ducking", "suspended", "inactive"),
  /// "controllable", "hasVideo", "hasAudio" (bools), "largestVideoWidth",
  /// "largestVideoHeight" (ints: natural size in video pixels of the largest
  /// playing video, 0 when none plays), "pictureInPictureDisabled" (bool: that
  /// video cannot enter Picture in Picture, for example disablePictureInPicture),
  /// "actions" (list of strings: play, pause, previousTrack, nextTrack,
  /// seekBackward, seekForward, seekTo, scrubTo, skipAd, stop,
  /// enterPictureInPicture, exitPictureInPicture, enterAutoPictureInPicture
  /// (the page handles "enterpictureinpicture"), toggleMicrophone,
  /// toggleCamera, hangUp, previousSlide, nextSlide), "title", "artist",
  /// "album", "sourceTitle" (strings), "position" (dictionary, absent when
  /// unknown: "duration", "position", "rate" (doubles, seconds), "live"
  /// (bool: infinite duration), "ended" (bool), "lastUpdated" (double,
  /// seconds since 1970)), "pictureInPicture" (bool), "microphoneState"
  /// ("unknown", "muted", "unmuted"), "cameraState" ("unknown", "on", "off"),
  /// "volume" (double, SetVolume). Later fields are added as new keys.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefDictionaryValue> GetState() = 0;

  ///
  /// Runs |action| on the media session, or on the players when the session
  /// is not controllable: "play", "pause", "stop", "previousTrack",
  /// "nextTrack", "skipAd", "seekBy" (|args| "delta", seconds), "seekTo" and
  /// "scrubTo" (|args| "time", seconds), "toggleMicrophone", "toggleCamera",
  /// "hangUp", "previousSlide", "nextSlide". Returns false for an unknown
  /// action or when there is nothing to run it on.
  ///
  /*--cef(optional_param=args)--*/
  virtual bool ExecuteAction(const CefString& action,
                             CefRefPtr<CefDictionaryValue> args) = 0;

  ///
  /// Sets the tab volume, 0 to 1 (default 1, not persisted). It scales every
  /// media element of the browser, including later ones. Web Audio is not
  /// affected.
  ///
  /*--cef()--*/
  virtual void SetVolume(double volume) = 0;

  ///
  /// Returns the tab volume.
  ///
  /*--cef()--*/
  virtual double GetVolume() = 0;

  ///
  /// Enters video Picture in Picture for the largest playing video without a
  /// user gesture. Returns false if no video plays or the largest playing
  /// video cannot enter Picture in Picture (disablePictureInPicture). The
  /// result arrives as "pictureInPicture" in GetState.
  ///
  /*--cef()--*/
  virtual bool RequestPictureInPicture() = 0;

  ///
  /// Closes the Picture in Picture window of this browser, if any. |behavior|
  /// 0: close only; 1: close and pause the video (the user's close); 2: close
  /// and focus the opener tab (back to tab).
  ///
  /*--cef()--*/
  virtual void ExitPictureInPicture(int behavior) = 0;
};

///
/// One session of Picture in Picture shown in the embedder's own window: a
/// video (EM-4) or, with GetState "kind" "document", a Document Picture in
/// Picture page (EM-7: GetVideoView is the page's view, "naturalWidth" and
/// "naturalHeight" are the size the page asked for, and only "close" runs).
/// The methods of this class must be called on the browser process UI thread.
///
/*--cef(source=library,added=experimental)--*/
class CefPictureInPictureWindow : public virtual CefBaseRefCounted {
 public:
  ///
  /// Returns true until the session ends.
  ///
  /*--cef()--*/
  virtual bool IsValid() = 0;

  ///
  /// Returns the view that shows the video. The embedder puts it in its
  /// window.
  ///
  /*--cef()--*/
  virtual CefWindowHandle GetVideoView() = 0;

  ///
  /// Returns the window state as a dictionary (natural size, source bounds,
  /// playback state, controls, microphone, camera, position, source title).
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefDictionaryValue> GetState() = 0;

  ///
  /// Reports the embedder window's frame in screen coordinates with a
  /// top-left origin, and whether it is visible.
  ///
  /*--cef()--*/
  virtual void SetWindowFrame(const CefRect& frame, bool visible) = 0;

  ///
  /// Runs a window control: "togglePlayPause", "nextTrack", "previousTrack",
  /// "skipAd", "toggleMicrophone", "toggleCamera", "hangUp", "nextSlide",
  /// "previousSlide", "seekTo" (|args| "time"), "setMuted" (|args| "muted"),
  /// "close" (|args| "behavior", as CefMediaController::ExitPictureInPicture).
  ///
  /*--cef(optional_param=args)--*/
  virtual void ExecuteAction(const CefString& action,
                             CefRefPtr<CefDictionaryValue> args) = 0;
};

#endif  // CEF_API_ADDED(CEF_EXPERIMENTAL)

#endif  // CEF_INCLUDE_CEF_MEDIA_CONTROLLER_H_
