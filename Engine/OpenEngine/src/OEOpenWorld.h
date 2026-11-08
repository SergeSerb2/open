#pragma once
#import "OEInternal.h"

CefRefPtr<CefV8Context> OEOpenWorldContext(CefRefPtr<CefBrowser> browser,
                                         CefRefPtr<CefFrame> frame);
bool OEOpenWorldRendererMessage(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefRefPtr<CefProcessMessage> message);
void OEOpenWorldBrowserDestroyed(int browserID);
