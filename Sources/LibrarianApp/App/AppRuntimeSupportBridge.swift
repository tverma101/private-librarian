import LibrarianAppSupport

// Keep the SwiftUI shell readable while the bookmark/transcription runtime
// policy lives in its separately testable support target.
typealias SecurityScopedBookmarkLease = LibrarianAppSupport.SecurityScopedBookmarkLease
typealias AppLocalTranscription = LibrarianAppSupport.AppLocalTranscription
