/**
 * TDLib TL 类型常量集中管理（M2）。
 * 所有 td_send/td_execute 的 @type 与更新流 @type 一律引用本文件，禁止散落魔法字符串。
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

/** TDLib 通用字段名 */
export class TdField {
  static readonly TYPE: string = '@type';
  static readonly EXTRA: string = '@extra';
  static readonly CLIENT_ID: string = '@client_id';
  static readonly MESSAGE: string = 'message';
  static readonly VERSION: string = 'version';
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
}
