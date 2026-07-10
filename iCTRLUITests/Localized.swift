import Foundation

/// Lightweight, dependency-free localization for the on-device notifications and
/// their action buttons. iCTRL ships as a re-signed IPA without a .lproj bundle,
/// so instead of NSLocalizedString we key a small in-code table by the system
/// language and fall back to English. Action titles carry an emoji so Allow/Deny
/// etc. are visually distinguishable at a glance.
///
/// Supported: English, 简体中文, 繁體中文, 日本語, 한국어, Español, Deutsch, Русский.
enum L10n {
    enum Lang { case en, zhHans, zhHant, ja, ko, es, de, ru }

    /// The active language bucket, from the user's preferred languages.
    static let lang: Lang = {
        guard let first = Locale.preferredLanguages.first?.lowercased() else { return .en }
        if first.hasPrefix("zh") {
            if first.contains("hant") || first.contains("tw") || first.contains("hk") || first.contains("mo") {
                return .zhHant
            }
            return .zhHans
        }
        if first.hasPrefix("ja") { return .ja }
        if first.hasPrefix("ko") { return .ko }
        if first.hasPrefix("es") { return .es }
        if first.hasPrefix("de") { return .de }
        if first.hasPrefix("ru") { return .ru }
        return .en
    }()

    /// Look up a key; returns the string for the active language (English fallback).
    static func t(_ key: Key) -> String {
        let row = table[key] ?? [:]
        return row[lang] ?? row[.en] ?? ""
    }

    enum Key {
        case allow, deny, enableRemote, disableRemote, stopServer, copyLogs
        case serverReadyTitle, serverFailedTitle, serverStoppedTitle
        case remoteDisabledTitle, remoteFailedTitle, enableLocalNetworkTitle
        case authRequestTitle
        case localOnlyBody, longPressRemoteOrStop, longPressDisableOrStop
        case longPressCopyLogs, serverStoppedBody
        case remoteFailedBody, remoteDisabledBody
        case authRequestBody       // %@ = client name
        case onDeviceOnlySuffix
        case pairRequestTitle
        case pairRequestBody       // %1$@ = client name, %2$@ = fingerprint
    }

    // key → (lang → text). English is the required fallback for every key.
    private static let table: [Key: [Lang: String]] = [
        // ── Action buttons (distinguishing emoji) ──
        .allow: [.en: "✅ Allow", .zhHans: "✅ 允许", .zhHant: "✅ 允許", .ja: "✅ 許可",
                 .ko: "✅ 허용", .es: "✅ Permitir", .de: "✅ Zulassen", .ru: "✅ Разрешить"],
        .deny: [.en: "⛔️ Deny", .zhHans: "⛔️ 拒绝", .zhHant: "⛔️ 拒絕", .ja: "⛔️ 拒否",
                .ko: "⛔️ 거부", .es: "⛔️ Denegar", .de: "⛔️ Ablehnen", .ru: "⛔️ Отклонить"],
        .enableRemote: [.en: "🌐 Enable Remote Access", .zhHans: "🌐 开启远程访问", .zhHant: "🌐 開啟遠端存取", .ja: "🌐 リモートを有効化",
                        .ko: "🌐 원격 접속 켜기", .es: "🌐 Activar acceso remoto", .de: "🌐 Fernzugriff aktivieren", .ru: "🌐 Включить удалённый доступ"],
        .disableRemote: [.en: "🔒 Disable Remote Access", .zhHans: "🔒 关闭远程访问", .zhHant: "🔒 關閉遠端存取", .ja: "🔒 リモートを無効化",
                         .ko: "🔒 원격 접속 끄기", .es: "🔒 Desactivar acceso remoto", .de: "🔒 Fernzugriff deaktivieren", .ru: "🔒 Выключить удалённый доступ"],
        .stopServer: [.en: "🛑 Stop Server", .zhHans: "🛑 停止服务", .zhHant: "🛑 停止服務", .ja: "🛑 サーバー停止",
                      .ko: "🛑 서버 중지", .es: "🛑 Detener servidor", .de: "🛑 Server stoppen", .ru: "🛑 Остановить сервер"],
        .copyLogs: [.en: "📋 Copy Logs", .zhHans: "📋 复制日志", .zhHant: "📋 複製日誌", .ja: "📋 ログをコピー",
                    .ko: "📋 로그 복사", .es: "📋 Copiar registros", .de: "📋 Logs kopieren", .ru: "📋 Копировать логи"],

        // ── Notification titles ──
        .serverReadyTitle: [.en: "🟢 iCTRL Server Ready", .zhHans: "🟢 iCTRL 服务已就绪", .zhHant: "🟢 iCTRL 服務已就緒", .ja: "🟢 iCTRL サーバー準備完了",
                            .ko: "🟢 iCTRL 서버 준비됨", .es: "🟢 Servidor iCTRL listo", .de: "🟢 iCTRL-Server bereit", .ru: "🟢 Сервер iCTRL готов"],
        .serverFailedTitle: [.en: "🔴 iCTRL Server Failed", .zhHans: "🔴 iCTRL 服务启动失败", .zhHant: "🔴 iCTRL 服務啟動失敗", .ja: "🔴 iCTRL サーバー起動失敗",
                             .ko: "🔴 iCTRL 서버 시작 실패", .es: "🔴 Error del servidor iCTRL", .de: "🔴 iCTRL-Server fehlgeschlagen", .ru: "🔴 Сбой сервера iCTRL"],
        .serverStoppedTitle: [.en: "⏹️ iCTRL Server Stopped", .zhHans: "⏹️ iCTRL 服务已停止", .zhHant: "⏹️ iCTRL 服務已停止", .ja: "⏹️ iCTRL サーバー停止",
                              .ko: "⏹️ iCTRL 서버 중지됨", .es: "⏹️ Servidor iCTRL detenido", .de: "⏹️ iCTRL-Server gestoppt", .ru: "⏹️ Сервер iCTRL остановлен"],
        .remoteDisabledTitle: [.en: "🔒 Remote Access Disabled", .zhHans: "🔒 远程访问已关闭", .zhHant: "🔒 遠端存取已關閉", .ja: "🔒 リモートアクセス無効",
                               .ko: "🔒 원격 접속 꺼짐", .es: "🔒 Acceso remoto desactivado", .de: "🔒 Fernzugriff deaktiviert", .ru: "🔒 Удалённый доступ выключен"],
        .remoteFailedTitle: [.en: "🔴 Remote Access Failed", .zhHans: "🔴 远程访问失败", .zhHant: "🔴 遠端存取失敗", .ja: "🔴 リモートアクセス失敗",
                             .ko: "🔴 원격 접속 실패", .es: "🔴 Acceso remoto fallido", .de: "🔴 Fernzugriff fehlgeschlagen", .ru: "🔴 Сбой удалённого доступа"],
        .enableLocalNetworkTitle: [.en: "⚠️ Enable Local Network for iCTRL", .zhHans: "⚠️ 请为 iCTRL 开启本地网络", .zhHant: "⚠️ 請為 iCTRL 開啟區域網路", .ja: "⚠️ iCTRL のローカルネットワークを許可",
                                   .ko: "⚠️ iCTRL 로컬 네트워크 허용", .es: "⚠️ Activa la red local para iCTRL", .de: "⚠️ Lokales Netzwerk für iCTRL aktivieren", .ru: "⚠️ Разрешите локальную сеть для iCTRL"],
        .authRequestTitle: [.en: "🔐 Authorization Request", .zhHans: "🔐 授权请求", .zhHant: "🔐 授權請求", .ja: "🔐 認証リクエスト",
                            .ko: "🔐 인증 요청", .es: "🔐 Solicitud de autorización", .de: "🔐 Autorisierungsanfrage", .ru: "🔐 Запрос авторизации"],

        // ── Bodies / fragments ──
        .localOnlyBody: [.en: "Running on 127.0.0.1:8200 (local only)", .zhHans: "运行于 127.0.0.1:8200(仅本机)", .zhHant: "執行於 127.0.0.1:8200(僅本機)", .ja: "127.0.0.1:8200 で稼働中(ローカルのみ)",
                         .ko: "127.0.0.1:8200 에서 실행 중(로컬 전용)", .es: "En ejecución en 127.0.0.1:8200 (solo local)", .de: "Läuft auf 127.0.0.1:8200 (nur lokal)", .ru: "Работает на 127.0.0.1:8200 (только локально)"],
        .longPressRemoteOrStop: [.en: "Long press for Remote Access or Stop Server", .zhHans: "长按可开启远程访问或停止服务", .zhHant: "長按可開啟遠端存取或停止服務", .ja: "長押しでリモート有効化／サーバー停止",
                                 .ko: "길게 눌러 원격 접속 또는 서버 중지", .es: "Mantén pulsado para acceso remoto o detener servidor", .de: "Lang drücken für Fernzugriff oder Server stoppen", .ru: "Удерживайте для удалённого доступа или остановки сервера"],
        .longPressDisableOrStop: [.en: "Long press to Disable Remote or Stop Server", .zhHans: "长按可关闭远程访问或停止服务", .zhHant: "長按可關閉遠端存取或停止服務", .ja: "長押しでリモート無効化／サーバー停止",
                                  .ko: "길게 눌러 원격 접속 끄기 또는 서버 중지", .es: "Mantén pulsado para desactivar remoto o detener servidor", .de: "Lang drücken zum Deaktivieren oder Server stoppen", .ru: "Удерживайте для отключения удалённого доступа или остановки"],
        .longPressCopyLogs: [.en: "Long press to Copy Logs", .zhHans: "长按可复制日志", .zhHant: "長按可複製日誌", .ja: "長押しでログをコピー",
                             .ko: "길게 눌러 로그 복사", .es: "Mantén pulsado para copiar registros", .de: "Lang drücken zum Kopieren der Logs", .ru: "Удерживайте, чтобы скопировать логи"],
        .serverStoppedBody: [.en: "The automation server has stopped.", .zhHans: "自动化服务已停止。", .zhHant: "自動化服務已停止。", .ja: "オートメーションサーバーが停止しました。",
                             .ko: "자동화 서버가 중지되었습니다.", .es: "El servidor de automatización se ha detenido.", .de: "Der Automatisierungsserver wurde gestoppt.", .ru: "Сервер автоматизации остановлен."],
        .remoteDisabledBody: [.en: "Now local only at 127.0.0.1:8200", .zhHans: "现在仅本机可访问 127.0.0.1:8200", .zhHant: "現在僅本機可存取 127.0.0.1:8200", .ja: "現在は 127.0.0.1:8200 のローカルのみ",
                              .ko: "이제 127.0.0.1:8200 로컬 전용", .es: "Ahora solo local en 127.0.0.1:8200", .de: "Jetzt nur lokal unter 127.0.0.1:8200", .ru: "Теперь только локально на 127.0.0.1:8200"],
        .remoteFailedBody: [.en: "iCTRL is listening but %@ can't be reached — likely the Local Network permission. Open the iCTRL app once and allow Local Network, then reconnect. (localhost still works.)",
                            .zhHans: "iCTRL 已在监听,但无法访问 %@ —— 可能是本地网络权限未开启。请打开 iCTRL App 允许本地网络后重连。(localhost 仍可用)",
                            .zhHant: "iCTRL 已在監聽,但無法存取 %@ —— 可能是區域網路權限未開啟。請開啟 iCTRL App 允許區域網路後重連。(localhost 仍可用)",
                            .ja: "iCTRL は待受中ですが %@ に到達できません — ローカルネットワーク権限が原因の可能性。iCTRL アプリを開いて許可し、再接続してください。(localhost は利用可)",
                            .ko: "iCTRL 가 수신 중이지만 %@ 에 연결할 수 없습니다 — 로컬 네트워크 권한 문제일 수 있습니다. iCTRL 앱을 열어 로컬 네트워크를 허용한 뒤 다시 연결하세요. (localhost 는 사용 가능)",
                            .es: "iCTRL está escuchando pero no se puede acceder a %@ — probablemente el permiso de Red local. Abre la app iCTRL, permite la Red local y vuelve a conectar. (localhost sigue funcionando)",
                            .de: "iCTRL lauscht, aber %@ ist nicht erreichbar — vermutlich die Berechtigung „Lokales Netzwerk“. Öffne die iCTRL-App, erlaube das lokale Netzwerk und verbinde dich neu. (localhost funktioniert weiterhin)",
                            .ru: "iCTRL слушает, но %@ недоступен — вероятно, нет разрешения на локальную сеть. Откройте приложение iCTRL, разрешите локальную сеть и переподключитесь. (localhost по-прежнему работает)"],
        .authRequestBody: [.en: "\"%@\" wants to control this device.\nLong press to Allow or Deny",
                           .zhHans: "“%@” 请求控制此设备。\n长按以允许或拒绝",
                           .zhHant: "「%@」請求控制此裝置。\n長按以允許或拒絕",
                           .ja: "「%@」がこのデバイスの操作を要求しています。\n長押しで許可または拒否",
                           .ko: "\"%@\"이(가) 이 기기의 제어를 요청합니다.\n길게 눌러 허용 또는 거부",
                           .es: "\"%@\" quiere controlar este dispositivo.\nMantén pulsado para permitir o denegar",
                           .de: "„%@“ möchte dieses Gerät steuern.\nLang drücken zum Zulassen oder Ablehnen",
                           .ru: "«%@» хочет управлять этим устройством.\nУдерживайте, чтобы разрешить или отклонить"],
        .pairRequestTitle: [.en: "🔑 Pairing Request", .zhHans: "🔑 配对请求", .zhHant: "🔑 配對請求", .ja: "🔑 ペアリング要求",
                            .ko: "🔑 페어링 요청", .es: "🔑 Solicitud de emparejamiento", .de: "🔑 Kopplungsanfrage", .ru: "🔑 Запрос сопряжения"],
        .pairRequestBody: [.en: "\"%1$@\" wants to pair (encrypted).\nKey fingerprint: %2$@\nLong press to Allow or Deny",
                           .zhHans: "“%1$@” 请求配对(加密连接)。\n密钥指纹:%2$@\n长按以允许或拒绝",
                           .zhHant: "「%1$@」請求配對(加密連線)。\n金鑰指紋:%2$@\n長按以允許或拒絕",
                           .ja: "「%1$@」がペアリング(暗号化)を要求しています。\n鍵フィンガープリント:%2$@\n長押しで許可または拒否",
                           .ko: "\"%1$@\"이(가) 페어링(암호화)을 요청합니다.\n키 지문: %2$@\n길게 눌러 허용 또는 거부",
                           .es: "\"%1$@\" quiere emparejarse (cifrado).\nHuella de clave: %2$@\nMantén pulsado para permitir o denegar",
                           .de: "„%1$@“ möchte sich koppeln (verschlüsselt).\nSchlüssel-Fingerabdruck: %2$@\nLang drücken zum Zulassen oder Ablehnen",
                           .ru: "«%1$@» хочет выполнить сопряжение (шифрование).\nОтпечаток ключа: %2$@\nУдерживайте, чтобы разрешить или отклонить"],
        .onDeviceOnlySuffix: [.en: "reachable on-device only; connect over Wi-Fi for LAN access",
                              .zhHans: "仅本机可访问;请连接 Wi-Fi 以支持局域网访问",
                              .zhHant: "僅本機可存取;請連接 Wi-Fi 以支援區域網路存取",
                              .ja: "端末上のみ到達可能;LAN 利用には Wi-Fi 接続が必要",
                              .ko: "기기에서만 접근 가능; LAN 접속은 Wi-Fi 연결 필요",
                              .es: "accesible solo en el dispositivo; conéctate por Wi-Fi para acceso LAN",
                              .de: "nur auf dem Gerät erreichbar; für LAN-Zugriff mit WLAN verbinden",
                              .ru: "доступно только на устройстве; для доступа по LAN подключитесь к Wi-Fi"],
    ]
}
