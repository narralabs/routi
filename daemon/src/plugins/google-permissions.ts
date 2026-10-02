export type PermissionRule = 'allow' | 'ask' | 'deny'
export type PermissionGroup = { id: string; label: string; scopes: string[]; tools: string[] }
const group = (id: string, label: string, scopes: string[], tools: string[]): PermissionGroup => ({
  id, label, scopes: scopes.map(scope => `https://www.googleapis.com/auth/${scope}`), tools,
})

// Explicit tool names: a new or unclassified tool is blocked until reviewed.
export const googlePermissions: Record<string, PermissionGroup[]> = {
  gmail: [
    group('read', 'Read email', ['gmail.readonly', 'gmail.modify'], ['get_message', 'get_thread', 'get_draft', 'list_drafts', 'list_labels', 'list_filters', 'search_threads']),
    group('send', 'Send email', ['gmail.send', 'gmail.compose', 'gmail.modify'], ['gmail_send_draft', 'send_message', 'reply', 'forward']),
    group('write', 'Manage drafts and messages', ['gmail.modify'], ['create_draft', 'update_draft', 'delete_draft', 'create_filter', 'create_label', 'delete_label', 'update_label', 'label_message', 'label_thread', 'unlabel_message', 'unlabel_thread', 'apply_sensitive_message_label', 'apply_sensitive_thread_label', 'update_message_labels', 'mark_message_spam', 'mark_thread_spam', 'unmark_message_spam', 'unmark_thread_spam', 'trash_message', 'trash_thread', 'untrash_message', 'untrash_thread']),
  ],
  google_calendar: [
    group('read', 'Read calendars and events', ['calendar.readonly', 'calendar', 'calendar.events.readonly', 'calendar.events', 'calendar.calendarlist.readonly', 'calendar.events.freebusy'], ['list_calendars', 'list_events', 'get_event', 'search_events', 'suggest_time']),
    group('write', 'Manage events', ['calendar.events', 'calendar'], ['create_event', 'update_event', 'delete_event', 'respond_to_event']),
  ],
  google_drive: [
    group('read', 'Read files', ['drive.readonly', 'drive.file', 'drive'], ['search_files', 'list_recent_files', 'get_file_metadata', 'get_file_permissions', 'read_file_content', 'download_file_content']),
    group('write', 'Manage files used with Routi', ['drive.file', 'drive'], ['create_file', 'copy_file']),
  ],
  google_docs: [
    group('read', 'Read documents', ['documents.readonly', 'documents', 'drive.readonly', 'drive'], ['read_doc']),
    group('write', 'Edit documents', ['documents', 'drive'], ['update_doc']),
  ],
}

export function hasScope(group: PermissionGroup, scopes: string[]): boolean {
  return group.scopes.some(scope => scopes.includes(scope)) || (group.scopes.some(scope => scope.includes('/gmail.')) && scopes.includes('https://mail.google.com/'))
}
