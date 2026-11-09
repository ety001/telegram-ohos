/**
 * TDLib TL 类型常量集中管理（M2 建立，M3 增补消息收发类）。
 * 所有 td_send/td_execute 的 @type 与更新流 @type 一律引用本文件，禁止散落魔法字符串。
 * 注意：对象字面量的键受 ArkTS 限制须为字符串字面量（arkts-identifiers-as-prop-names），
 * 写入侧字面量键与读取侧 TdField 常量保持同名对应。
 */
export class TdReq {
  static readonly SET_TDLIB_PARAMETERS: string = 'setTdlibParameters';
  static readonly SET_AUTHENTICATION_PHONE_NUMBER: string = 'setAuthenticationPhoneNumber';
  static readonly RESEND_AUTHENTICATION_CODE: string = 'resendAuthenticationCode';
  static readonly CHECK_AUTHENTICATION_CODE: string = 'checkAuthenticationCode';
  static readonly CHECK_AUTHENTICATION_PASSWORD: string = 'checkAuthenticationPassword';
  static readonly REQUEST_QR_CODE_AUTHENTICATION: string = 'requestQrCodeAuthentication';
  static readonly LOG_OUT: string = 'logOut';
  static readonly ADD_PROXY: string = 'addProxy';
  static readonly TEST_PROXY: string = 'testProxy';
  static readonly CLOSE: string = 'close';
  static readonly GET_VERSION: string = 'getVersion';
  // 会话列表（1.8.63 schema：getChats/loadChats 无 offset 参数，分页由 loadChats 增量加载）
  static readonly GET_CHATS: string = 'getChats';
  static readonly LOAD_CHATS: string = 'loadChats';
  static readonly GET_CHAT: string = 'getChat';
  // 消息收发（1.8.63 schema：sendMessage 无 message_thread_id/reply_to_message_id 平铺字段，
  // 主题/回复分别是 topic_id:MessageTopic 与 reply_to:InputMessageReplyTo 对象，纯文本发送可整体缺省）
  static readonly SEND_MESSAGE: string = 'sendMessage';
  // 1.8.63 schema：getChatHistory(chat_id, from_message_id, offset, limit, only_local) 返回 messages
  static readonly GET_CHAT_HISTORY: string = 'getChatHistory';
  static readonly VIEW_MESSAGES: string = 'viewMessages';
  static readonly OPEN_CHAT: string = 'openChat';
  static readonly CLOSE_CHAT: string = 'closeChat';
  static readonly DELETE_MESSAGES: string = 'deleteMessages';
  // 媒体下载（1.8.63 schema：downloadFile(file_id, priority, offset, limit, synchronous) 返回 file，
  // 尚无 suffix 参数——后版 schema 才引入，勿混用）
  static readonly DOWNLOAD_FILE: string = 'downloadFile';
  static readonly CANCEL_DOWNLOAD_FILE: string = 'cancelDownloadFile';
}

export class TdUpdate {
  static readonly AUTHORIZATION_STATE: string = 'updateAuthorizationState';
  static readonly OPTION: string = 'updateOption';
  // 会话列表（TDLib 契约：updateNewChat 保证先于该 chat 出现在 getChats 结果中）
  static readonly NEW_CHAT: string = 'updateNewChat';
  static readonly CHAT_POSITION: string = 'updateChatPosition';
  static readonly CHAT_LAST_MESSAGE: string = 'updateChatLastMessage';
  static readonly CHAT_READ_INBOX: string = 'updateChatReadInbox';
  static readonly CHAT_TITLE: string = 'updateChatTitle';
  static readonly CHAT_PHOTO: string = 'updateChatPhoto';
  // getChats/searchChats 的结果对象（@type=chats，结果与 update 走同一分发入口）
  static readonly CHATS: string = 'chats';
  // getChat 的结果对象（@type=chat，chats 结果缺项时的补拉响应）
  static readonly CHAT_RESULT: string = 'chat';
  // 消息收发（M3）
  static readonly NEW_MESSAGE: string = 'updateNewMessage';
  static readonly MESSAGE_SEND_SUCCEEDED: string = 'updateMessageSendSucceeded';
  static readonly MESSAGE_SEND_FAILED: string = 'updateMessageSendFailed';
  static readonly MESSAGE_CONTENT: string = 'updateMessageContent';
  static readonly DELETE_MESSAGES: string = 'updateDeleteMessages';
  static readonly CHAT_READ_OUTBOX: string = 'updateChatReadOutbox';
  // getChatHistory 的结果对象（@type=messages，含完整 message 数组；与 update 走同一分发入口）
  static readonly MESSAGES: string = 'messages';
  // 媒体下载进度/完成通知（updateFile.file：含 local.path / is_downloading_* / downloaded_size）
  static readonly UPDATE_FILE: string = 'updateFile';
}

export class AuthStateType {
  static readonly WAIT_TDLIB_PARAMETERS: string = 'authorizationStateWaitTdlibParameters';
  static readonly WAIT_PHONE_NUMBER: string = 'authorizationStateWaitPhoneNumber';
  static readonly WAIT_CODE: string = 'authorizationStateWaitCode';
  static readonly WAIT_OTHER_DEVICE: string = 'authorizationStateWaitOtherDeviceConfirmation';
  static readonly WAIT_REGISTRATION: string = 'authorizationStateWaitRegistration';
  static readonly WAIT_EMAIL_ADDRESS: string = 'authorizationStateWaitEmailAddress';
  static readonly WAIT_EMAIL_CODE: string = 'authorizationStateWaitEmailCode';
  static readonly WAIT_PASSWORD: string = 'authorizationStateWaitPassword';
  static readonly READY: string = 'authorizationStateReady';
  static readonly LOGGING_OUT: string = 'authorizationStateLoggingOut';
  static readonly CLOSING: string = 'authorizationStateClosing';
  static readonly CLOSED: string = 'authorizationStateClosed';
}

export class ErrorType {
  static readonly INVALID: string = 'error';
}

/** ChatList 子类型（chat_position.list['@type']） */
export class TdChatList {
  static readonly MAIN: string = 'chatListMain';
}

/** MessageContent 子类型（last_message.content['@type']，会话列表预览提取用） */
export class TdMessageContent {
  static readonly TEXT: string = 'messageText';
  static readonly PHOTO: string = 'messagePhoto';
  static readonly VIDEO: string = 'messageVideo';
  static readonly VIDEO_NOTE: string = 'messageVideoNote';
  static readonly DOCUMENT: string = 'messageDocument';
  static readonly VOICE_NOTE: string = 'messageVoiceNote';
  static readonly ANIMATION: string = 'messageAnimation';
  static readonly STICKER: string = 'messageSticker';
  static readonly AUDIO: string = 'messageAudio';
  static readonly LOCATION: string = 'messageLocation';
  static readonly CONTACT: string = 'messageContact';
  static readonly POLL: string = 'messagePoll';
  static readonly CALL: string = 'messageCall';
}

/** MessageSendingState 子类型（message.sending_state['@type']；字段缺省/null = 已发送） */
export class TdSendingState {
  static readonly PENDING: string = 'messageSendingStatePending';
  static readonly FAILED: string = 'messageSendingStateFailed';
}

/** InputMessageContent 子类型与配套包装类型名（sendMessage 入参用） */
export class TdInputMessage {
  static readonly INPUT_MESSAGE_TEXT: string = 'inputMessageText';
  static readonly FORMATTED_TEXT: string = 'formattedText';
}

/** MessageSource 子类型（viewMessages.source 用；1.8.63 为对象类型，非旧版 message_source 字符串） */
export class TdMessageSource {
  static readonly CHAT_HISTORY: string = 'messageSourceChatHistory';
}

/** TDLib 通用字段名 */
export class TdField {
  static readonly TYPE: string = '@type';
  static readonly EXTRA: string = '@extra';
  static readonly CLIENT_ID: string = '@client_id';
  static readonly MESSAGE: string = 'message';
  static readonly VERSION: string = 'version';
  static readonly ERROR: string = 'error';
  // chat / update 通用字段
  static readonly ID: string = 'id';
  static readonly CHAT_ID: string = 'chat_id';
  static readonly TITLE: string = 'title';
  static readonly PHOTO: string = 'photo';
  static readonly CHAT: string = 'chat';
  static readonly CHAT_LIST: string = 'chat_list';
  static readonly LIST: string = 'list';
  static readonly POSITION: string = 'position';
  static readonly POSITIONS: string = 'positions';
  static readonly ORDER: string = 'order';
  static readonly IS_PINNED: string = 'is_pinned';
  static readonly UNREAD_COUNT: string = 'unread_count';
  static readonly CHAT_IDS: string = 'chat_ids';
  static readonly LAST_MESSAGE: string = 'last_message';
  static readonly DATE: string = 'date';
  static readonly CONTENT: string = 'content';
  static readonly TEXT: string = 'text';
  static readonly LIMIT: string = 'limit';
  // message / 消息请求通用字段（M3）
  static readonly MESSAGE_ID: string = 'message_id';
  static readonly MESSAGE_IDS: string = 'message_ids';
  static readonly NEW_CONTENT: string = 'new_content';
  static readonly OLD_MESSAGE_ID: string = 'old_message_id';
  static readonly SENDING_STATE: string = 'sending_state';
  static readonly IS_OUTGOING: string = 'is_outgoing';
  static readonly CAN_RETRY: string = 'can_retry';
  static readonly FROM_MESSAGE_ID: string = 'from_message_id';
  static readonly ONLY_LOCAL: string = 'only_local';
  static readonly FORCE_READ: string = 'force_read';
  static readonly SOURCE: string = 'source';
  static readonly INPUT_MESSAGE_CONTENT: string = 'input_message_content';
  static readonly REVOKE: string = 'revoke';
  static readonly FROM_CACHE: string = 'from_cache';
  static readonly LAST_READ_OUTBOX_MESSAGE_ID: string = 'last_read_outbox_message_id';
  // 媒体内容与文件（M3-media；字段名以 1.8.63 td_api.tl 为准）
  // 注意：messagePhoto.photo 复用上方 chat.photo 的 PHOTO 常量（同名同值）
  static readonly VIDEO: string = 'video';
  static readonly VIDEO_NOTE: string = 'video_note';
  static readonly DOCUMENT: string = 'document';
  static readonly VOICE_NOTE: string = 'voice_note';
  static readonly ANIMATION: string = 'animation';
  static readonly STICKER: string = 'sticker';
  static readonly CAPTION: string = 'caption';
  static readonly SIZES: string = 'sizes';
  static readonly MINITHUMBNAIL: string = 'minithumbnail';
  static readonly THUMBNAIL: string = 'thumbnail';
  static readonly DATA: string = 'data';
  static readonly WIDTH: string = 'width';
  static readonly HEIGHT: string = 'height';
  static readonly DURATION: string = 'duration';
  static readonly FILE_NAME: string = 'file_name';
  static readonly MIME_TYPE: string = 'mime_type';
  static readonly SUPPORTS_STREAMING: string = 'supports_streaming';
  // file / localFile / downloadFile 请求字段
  static readonly FILE: string = 'file';
  static readonly LOCAL: string = 'local';
  static readonly PATH: string = 'path';
  static readonly SIZE: string = 'size';
  static readonly EXPECTED_SIZE: string = 'expected_size';
  static readonly IS_DOWNLOADING_ACTIVE: string = 'is_downloading_active';
  static readonly IS_DOWNLOADING_COMPLETED: string = 'is_downloading_completed';
  static readonly DOWNLOADED_SIZE: string = 'downloaded_size';
  static readonly PRIORITY: string = 'priority';
  static readonly OFFSET: string = 'offset';
  static readonly SYNCHRONOUS: string = 'synchronous';
}
