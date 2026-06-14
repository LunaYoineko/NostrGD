extends Control

const NostrUtils = preload("res://scripts/nostr_utils.gd")

@onready var private_key_input: TextEdit = $Sidebar/SidebarInner/AccountSection/VBoxContainer/LoginContainer/PrivateKeyInput
@onready var status_label: Label = $Sidebar/SidebarInner/StatusSection/StatusLabel
@onready var message_input: LineEdit = $MainPanel/InputBar/HBoxContainer/MessageInput
@onready var timeline: VBoxContainer = $MainPanel/ScrollContainer/Timeline
@onready var register_name_input: LineEdit = $Sidebar/SidebarInner/AccountSection/VBoxContainer/CreateContainer/RegisterNameInput
@onready var register_display_input: LineEdit = $Sidebar/SidebarInner/AccountSection/VBoxContainer/CreateContainer/RegisterDisplayInput
@onready var register_picture_input: LineEdit = $Sidebar/SidebarInner/AccountSection/VBoxContainer/CreateContainer/RegisterPictureInput
@onready var register_banner_input: LineEdit = $Sidebar/SidebarInner/AccountSection/VBoxContainer/CreateContainer/RegisterBannerInput
@onready var register_lud16_input: LineEdit = $Sidebar/SidebarInner/AccountSection/VBoxContainer/CreateContainer/RegisterLud16Input
@onready var auth_choice_hbox: HBoxContainer = $Sidebar/SidebarInner/AccountSection/VBoxContainer/AuthChoiceHBox
@onready var login_container: VBoxContainer = $Sidebar/SidebarInner/AccountSection/VBoxContainer/LoginContainer
@onready var create_container: VBoxContainer = $Sidebar/SidebarInner/AccountSection/VBoxContainer/CreateContainer
@onready var logged_in_container: VBoxContainer = $Sidebar/SidebarInner/AccountSection/VBoxContainer/LoggedInContainer
@onready var section_header: Label = $MainPanel/SectionHeader/HeaderLabel
@onready var nav_buttons: Array[Button] = [
	$Sidebar/SidebarInner/NavSection/NavMenu/NavTimeline,
	$Sidebar/SidebarInner/NavSection/NavMenu/NavNotifications,
	$Sidebar/SidebarInner/NavSection/NavMenu/NavDM,
	$Sidebar/SidebarInner/NavSection/NavMenu/NavProfile,
	$Sidebar/SidebarInner/NavSection/NavMenu/NavSettings
]

enum Section { TIMELINE, NOTIFICATIONS, DM, PROFILE, SETTINGS }
var _current_section: int = Section.TIMELINE

var RELAY_URL: Array[String] = []


var received_event_ids: Dictionary = {}
var profile_cache: Dictionary = {}
var pending_labels: Dictionary = {}
var pubkey_request_pool: Array[String] = []
var pool_timer: Timer
var _timeline_update_timer: Timer
var _pending_sorted_timeline: Array = []
const TIMELINE_MAX_ITEMS: int = 20
const MAX_NOTIFICATIONS: int = 20

enum UIState { LOGGED_OUT, LOGIN_FORM, CREATE_FORM, LOGGED_IN }
var _ui_state: int = UIState.LOGGED_OUT
var _is_profile_edit: bool = false

var _stamp_event_id: String = ""
var _stamp_pubkey: String = ""
var _zap_event_id: String = ""
var _zap_pubkey: String = ""
var _zap_buttons_by_pubkey: Dictionary = {}
var _liked_events: Dictionary = {}
var _zap_amount_input: LineEdit
var _zap_msg_input: LineEdit
var _zap_in_progress: bool = false
var _avatar_texture_cache: Dictionary = {}
var _image_texture_cache: Dictionary = {}
var _pending_embeds: Dictionary = {}
var _pending_notif_embeds: Dictionary = {}
var _invoice_label: Label
var _invoice_qr_rect: TextureRect
var _notifications_events: Array = []
var _dm_conversations: Dictionary = {}
var _reply_context: Dictionary = {}
var _file_dialog: FileDialog
var _notification_sub_id: String = ""
var _dm_sub_id: String = ""
var _reply_context_label: Label
var _timeline_paused: bool = false

func _ready() -> void:
	_apply_theme()
	_setup_stamp_popup()
	_setup_zap_popup()
	_setup_invoice_popup()

	var img_btn = Button.new()
	img_btn.text = "🖼️"
	img_btn.custom_minimum_size = Vector2(28, 24)
	img_btn.pressed.connect(_on_image_upload_button)
	$MainPanel/InputBar/HBoxContainer.add_child(img_btn)
	$MainPanel/InputBar/HBoxContainer.move_child(img_btn, 0)

	_reply_context_label = Label.new()
	_reply_context_label.add_theme_color_override("font_color", Color(0.5, 0.7, 1))
	_reply_context_label.add_theme_font_size_override("font_size", 11)
	_reply_context_label.visible = false
	_reply_context_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	$MainPanel/InputBar.add_child(_reply_context_label)
	$MainPanel/InputBar.move_child(_reply_context_label, 0)

	$MainPanel/ScrollContainer.get_v_scroll_bar().value_changed.connect(_on_timeline_scrolled)

	message_input.text_submitted.connect(func(text):
		if not text.strip_edges().is_empty():
			_on_send_button_pressed()
	)

	message_input.gui_input.connect(func(event):
		if event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed and not event.echo:
			_reply_context = {}
			_reply_context_label.visible = false
			_set_input_placeholder("")
			message_input.release_focus()
	)

	$Sidebar/SidebarInner/AccountSection/VBoxContainer/LoggedInContainer/DisconnectButton.visible = false

	NostrGD.Connected.connect(_on_nostr_connected)
	NostrGD.Disconnected.connect(_on_nostr_disconnected)
	NostrGD.EventReceived.connect(_on_nostr_event_received)
	NostrGD.NoticeReceived.connect(_on_nostr_notice)
	NostrGD.ExtensionAuthCompleted.connect(_on_extension_auth_completed)
	NostrGD.TimelineUpdated.connect(_on_nostr_timeline_updated)
	NostrGD.NwcResponseReceived.connect(_on_nostr_nwc_response)

	pool_timer = Timer.new()
	pool_timer.wait_time = 1.0
	pool_timer.autostart = false
	pool_timer.one_shot = false
	pool_timer.timeout.connect(_on_pool_timer_timeout)
	add_child(pool_timer)

	_timeline_update_timer = Timer.new()
	_timeline_update_timer.wait_time = 0.3
	_timeline_update_timer.one_shot = true
	_timeline_update_timer.timeout.connect(_apply_timeline_update)
	add_child(_timeline_update_timer)

	var saved_key = _load_private_key()
	if not saved_key.is_empty():
		private_key_input.text = saved_key
		if NostrGD.Login(saved_key):
			_set_ui_state(UIState.LOGGED_IN)
			status_label.text = "自動ログイン完了"
			NostrGD.TryInitNWC()
		else:
			_set_ui_state(UIState.LOGGED_OUT)
			status_label.text = "未ログイン"
	else:
		_set_ui_state(UIState.LOGGED_OUT)
		status_label.text = "未ログイン"

	var saved_relays = NostrGD.LoadRelayUrls()
	if saved_relays.size() > 0:
		for url in saved_relays:
			RELAY_URL.append(url)

	_build_sections()
	_switch_section(Section.TIMELINE)

	_connect_relays()

func _apply_theme() -> void:
	var window_bg = StyleBoxFlat.new()
	window_bg.bg_color = Color(0.09, 0.1, 0.12)

	var panel_bg = StyleBoxFlat.new()
	panel_bg.bg_color = Color(0.11, 0.12, 0.14)
	panel_bg.border_width_bottom = 1
	panel_bg.border_color = Color(0.18, 0.19, 0.22)

	var input_bg = StyleBoxFlat.new()
	input_bg.bg_color = Color(0.14, 0.15, 0.17)
	input_bg.border_width_bottom = 1
	input_bg.border_color = Color(0.25, 0.26, 0.3)

	var btn_bg = StyleBoxFlat.new()
	btn_bg.bg_color = Color(0.25, 0.45, 0.7)
	btn_bg.corner_radius_top_left = 4
	btn_bg.corner_radius_top_right = 4
	btn_bg.corner_radius_bottom_right = 4
	btn_bg.corner_radius_bottom_left = 4

	var btn_bg_hover = StyleBoxFlat.new()
	btn_bg_hover.bg_color = Color(0.3, 0.5, 0.8)
	btn_bg_hover.corner_radius_top_left = 4
	btn_bg_hover.corner_radius_top_right = 4
	btn_bg_hover.corner_radius_bottom_right = 4
	btn_bg_hover.corner_radius_bottom_left = 4

	var btn_bg_pressed = StyleBoxFlat.new()
	btn_bg_pressed.bg_color = Color(0.2, 0.35, 0.6)
	btn_bg_pressed.corner_radius_top_left = 4
	btn_bg_pressed.corner_radius_top_right = 4
	btn_bg_pressed.corner_radius_bottom_right = 4
	btn_bg_pressed.corner_radius_bottom_left = 4

	var sidebar_section = StyleBoxFlat.new()
	sidebar_section.bg_color = Color(0.1, 0.11, 0.13)
	sidebar_section.content_margin_left = 12
	sidebar_section.content_margin_right = 12
	sidebar_section.content_margin_top = 12
	sidebar_section.content_margin_bottom = 12

	var title_bar_bg = StyleBoxFlat.new()
	title_bar_bg.bg_color = Color(0.05, 0.06, 0.08)
	title_bar_bg.border_width_bottom = 1
	title_bar_bg.border_color = Color(0.2, 0.22, 0.25)

	var status_bg = StyleBoxFlat.new()
	status_bg.bg_color = Color(0.08, 0.09, 0.11)
	status_bg.content_margin_left = 12
	status_bg.content_margin_right = 12
	status_bg.content_margin_top = 8
	status_bg.content_margin_bottom = 12

	var timeline_header_bg = StyleBoxFlat.new()
	timeline_header_bg.bg_color = Color(0.05, 0.06, 0.08)
	timeline_header_bg.border_width_bottom = 1
	timeline_header_bg.border_color = Color(0.2, 0.22, 0.25)

	var input_bar_bg = StyleBoxFlat.new()
	input_bar_bg.bg_color = Color(0.08, 0.09, 0.11)
	input_bar_bg.border_width_top = 1
	input_bar_bg.border_color = Color(0.2, 0.22, 0.25)
	input_bar_bg.content_margin_left = 8
	input_bar_bg.content_margin_right = 8
	input_bar_bg.content_margin_top = 6
	input_bar_bg.content_margin_bottom = 6

	$Sidebar.add_theme_stylebox_override("panel", panel_bg)
	$Sidebar/SidebarInner/SidebarTitle.add_theme_stylebox_override("panel", title_bar_bg)
	$Sidebar/SidebarInner/StatusSection.add_theme_stylebox_override("panel", status_bg)
	$MainPanel/SectionHeader.add_theme_stylebox_override("panel", timeline_header_bg)
	$MainPanel/InputBar.add_theme_stylebox_override("panel", input_bar_bg)

	for btn in [$Sidebar/SidebarInner/AccountSection/VBoxContainer/AuthChoiceHBox/LoginChoiceBtn,
		$Sidebar/SidebarInner/AccountSection/VBoxContainer/AuthChoiceHBox/CreateChoiceBtn,
		$Sidebar/SidebarInner/AccountSection/VBoxContainer/LoginContainer/LoginConfirmBtn,
		$Sidebar/SidebarInner/AccountSection/VBoxContainer/CreateContainer/CreateBtnHBox/CreateConfirmBtn,
		$Sidebar/SidebarInner/AccountSection/VBoxContainer/CreateContainer/CreateBtnHBox/CreateBackBtn,
		$Sidebar/SidebarInner/AccountSection/VBoxContainer/ExtensionLogin,
		$Sidebar/SidebarInner/NavSection/NavMenu/NavTimeline,
		$Sidebar/SidebarInner/NavSection/NavMenu/NavNotifications,
		$Sidebar/SidebarInner/NavSection/NavMenu/NavDM,
		$Sidebar/SidebarInner/NavSection/NavMenu/NavProfile,
		$Sidebar/SidebarInner/NavSection/NavMenu/NavSettings,
		$MainPanel/InputBar/HBoxContainer/SendButton]:
		btn.add_theme_stylebox_override("normal", btn_bg)
		btn.add_theme_stylebox_override("hover", btn_bg_hover)
		btn.add_theme_stylebox_override("pressed", btn_bg_pressed)
		btn.add_theme_color_override("font_color", Color(1, 1, 1))

func _save_private_key(key: String) -> void:
	NostrGD.SavePrivateKey(key)
	print("NostrGD: 秘密鍵を保存しました。")

func _load_private_key() -> String:
	return NostrGD.LoadPrivateKey()

func _on_nostr_connected(url: String) -> void:
	status_label.text = "接続完了"

	if not pool_timer.is_processing():
		pool_timer.start()

	# NWC リレー（RELAY_URL に含まれないもの）にはタイムラインを要求しない
	if url in RELAY_URL:
		NostrGD.RequestTimeline("global_feed", 20, url)

	if NostrGD.IsLoggedIn:
		_start_notification_subscription()
		_start_dm_subscription()

func _on_nostr_disconnected(_url: String) -> void:
	pass

func _set_ui_state(state: int) -> void:
	_ui_state = state
	auth_choice_hbox.visible = (state == UIState.LOGGED_OUT)
	login_container.visible = (state == UIState.LOGIN_FORM)
	create_container.visible = (state == UIState.CREATE_FORM)
	logged_in_container.visible = (state == UIState.LOGGED_IN)
	$MainPanel/InputBar.visible = (state == UIState.LOGGED_IN)
	$Sidebar/SidebarInner/AccountSection/VBoxContainer/ExtensionLogin.visible = (state != UIState.LOGGED_IN)

	if state == UIState.LOGGED_IN:
		if _notification_sub_id.is_empty():
			_notification_sub_id = "notif_" + NostrGD.GetPublicKeyHex().left(8)
			_dm_sub_id = "dm_" + NostrGD.GetPublicKeyHex().left(8)
			_notifications_events.clear()
			_dm_conversations.clear()
		_start_notification_subscription()
		_start_dm_subscription()
	else:
		if not _notification_sub_id.is_empty():
			NostrGD.CloseSubscription(_notification_sub_id)
			_notification_sub_id = ""
		if not _dm_sub_id.is_empty():
			NostrGD.CloseSubscription(_dm_sub_id)
			_dm_sub_id = ""

func _on_show_login_form() -> void:
	_set_ui_state(UIState.LOGIN_FORM)

func _on_show_create_form() -> void:
	_set_ui_state(UIState.CREATE_FORM)

func _on_back_to_auth_choice() -> void:
	_is_profile_edit = false
	$Sidebar/SidebarInner/AccountSection/VBoxContainer/CreateContainer/CreateBtnHBox/CreateConfirmBtn.text = "作成"
	if NostrGD.IsLoggedIn:
		_set_ui_state(UIState.LOGGED_IN)
	else:
		_set_ui_state(UIState.LOGGED_OUT)

func _connect_relays() -> void:
	for relay_url in RELAY_URL:
		NostrGD.ConnectToRelay(relay_url)
	NostrGD.ActivateRelayProcessing()

func _build_sections() -> void:
	_build_notifications_section()
	_build_dm_section()
	_build_profile_section()
	_build_settings_section()

func _build_notifications_section() -> void:
	var panel = $MainPanel/NotificationsPanel
	var scroll = ScrollContainer.new()
	scroll.name = "NotifScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)
	var vbox = VBoxContainer.new()
	vbox.name = "NotifList"
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 2)
	scroll.add_child(vbox)

func _build_dm_section() -> void:
	var panel = $MainPanel/DMPanel
	var scroll = ScrollContainer.new()
	scroll.name = "DMScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)
	var vbox = VBoxContainer.new()
	vbox.name = "DMList"
	vbox.add_theme_constant_override("separation", 2)
	scroll.add_child(vbox)

	var input_hbox = HBoxContainer.new()
	input_hbox.name = "DMInputBar"
	panel.add_child(input_hbox)

	var dm_pk = LineEdit.new()
	dm_pk.name = "DMPubkey"
	dm_pk.placeholder_text = "送信先 pubkey hex"
	dm_pk.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input_hbox.add_child(dm_pk)

	var dm_input = LineEdit.new()
	dm_input.name = "DMMessage"
	dm_input.placeholder_text = "DMを入力..."
	dm_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input_hbox.add_child(dm_input)

	var dm_send = Button.new()
	dm_send.name = "DMSendButton"
	dm_send.text = "送信"
	dm_send.pressed.connect(_on_dm_send)
	input_hbox.add_child(dm_send)

func _build_profile_section() -> void:
	var panel = $MainPanel/ProfilePanel
	if panel.get_child_count() > 0:
		return

	var banner = TextureRect.new()
	banner.name = "ProfileBanner"
	banner.custom_minimum_size = Vector2(0, 200)
	banner.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	banner.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	banner.clip_contents = true
	panel.add_child(banner)

	var scroll = ScrollContainer.new()
	scroll.name = "ProfileScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)

	var margin = MarginContainer.new()
	margin.name = "ProfileMargin"
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(margin)

	var vbox = VBoxContainer.new()
	vbox.name = "ProfileVBox"
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	var header_hbox = HBoxContainer.new()
	header_hbox.name = "ProfileHeader"
	header_hbox.add_theme_constant_override("separation", 16)
	vbox.add_child(header_hbox)

	var arect = TextureRect.new()
	arect.name = "ProfileAvatar"
	arect.custom_minimum_size = Vector2(80, 80)
	arect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	arect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	arect.clip_contents = true
	arect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	arect.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	header_hbox.add_child(arect)

	var name_vbox = VBoxContainer.new()
	name_vbox.name = "ProfileNameSection"
	name_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_vbox.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header_hbox.add_child(name_vbox)

	var nl = Label.new()
	nl.name = "ProfileName"
	nl.add_theme_font_size_override("font_size", 22)
	name_vbox.add_child(nl)

	var al = Label.new()
	al.name = "ProfileAbout"
	al.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	al.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	name_vbox.add_child(al)

	var pl = Label.new()
	pl.name = "ProfilePubkey"
	pl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	pl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(pl)

	var ll = Label.new()
	ll.name = "ProfileLud"
	ll.add_theme_color_override("font_color", Color(0.5, 0.7, 1))
	vbox.add_child(ll)

	var eb = Button.new()
	eb.text = "プロフィールを編集"
	eb.pressed.connect(_on_profile_edit)
	vbox.add_child(eb)

	var cb = Button.new()
	cb.text = "Pubkey をコピー"
	cb.pressed.connect(func():
		DisplayServer.clipboard_set(NostrGD.GetPublicKeyHex())
		status_label.text = "Pubkey をコピーしました"
	)
	vbox.add_child(cb)

func _build_settings_section() -> void:
	var panel = $MainPanel/SettingsPanel
	var scroll = ScrollContainer.new()
	scroll.name = "SettingsScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)

	var margin = MarginContainer.new()
	margin.name = "SettingsMargin"
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(margin)

	var vbox = VBoxContainer.new()
	vbox.name = "SettingsVBox"
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	var relay_title = Label.new()
	relay_title.text = "🔄 接続リレー"
	relay_title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(relay_title)

	var add_hbox = HBoxContainer.new()
	add_hbox.name = "SettingsAddRelay"
	add_hbox.add_theme_constant_override("separation", 6)
	vbox.add_child(add_hbox)

	var relay_input = LineEdit.new()
	relay_input.name = "RelayInput"
	relay_input.placeholder_text = "wss://..."
	relay_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	relay_input.custom_minimum_size = Vector2(0, 32)
	var relay_input_node = relay_input
	add_hbox.add_child(relay_input)

	var add_btn = Button.new()
	add_btn.text = "追加"
	add_btn.custom_minimum_size = Vector2(80, 32)
	add_btn.pressed.connect(func():
		var url = relay_input_node.text.strip_edges()
		if url == "":
			return
		if url in RELAY_URL:
			status_label.text = "既に登録されています: " + url
			return
		RELAY_URL.append(url)
		NostrGD.ConnectToRelay(url)
		NostrGD.ActivateRelayProcessing()
		NostrGD.SaveRelayUrls(RELAY_URL)
		relay_input_node.clear()
		_refresh_settings_relays()
		_reset_timeline()
		status_label.text = "リレーを追加しました: " + url
	)
	add_hbox.add_child(add_btn)

	var relay_list = VBoxContainer.new()
	relay_list.name = "SettingsRelayList"
	vbox.add_child(relay_list)

	for url in RELAY_URL:
		_add_relay_row(relay_list, url)

	vbox.add_child(HSeparator.new())

	var nwc_title = Label.new()
	nwc_title.text = "⚡ ウォレット (NWC)"
	nwc_title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(nwc_title)

	var nwc_input = LineEdit.new()
	nwc_input.name = "NwcInput"
	nwc_input.placeholder_text = "nostr+walletconnect://..."
	nwc_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nwc_input.custom_minimum_size = Vector2(0, 32)
	if NostrGD.IsNwcConfigured:
		nwc_input.text = NostrGD.LoadNwcConnectionString()
	vbox.add_child(nwc_input)

	var nwc_hbox = HBoxContainer.new()
	nwc_hbox.add_theme_constant_override("separation", 6)
	vbox.add_child(nwc_hbox)

	var nwc_save_btn = Button.new()
	nwc_save_btn.text = "保存"
	nwc_save_btn.custom_minimum_size = Vector2(80, 32)
	nwc_save_btn.pressed.connect(func():
		var val = nwc_input.text.strip_edges()
		if val == "":
			NostrGD.ClearNwcConnectionString()
			status_label.text = "NWC 設定をクリアしました"
		else:
			NostrGD.SaveNwcConnectionString(val)
			if NostrGD.InitNWC(val):
				status_label.text = "NWC 接続文字列を保存・初期化しました"
			else:
				status_label.text = "NWC 接続文字列のパースに失敗しました"
	)
	nwc_hbox.add_child(nwc_save_btn)

	var nwc_status = Label.new()
	nwc_status.name = "NwcStatus"
	if NostrGD.IsNwcConfigured:
		nwc_status.text = "✅ NWC 設定済み"
		nwc_status.add_theme_color_override("font_color", Color(0.4, 0.8, 0.4))
	else:
		nwc_status.text = "未設定"
		nwc_status.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	nwc_hbox.add_child(nwc_status)

	var about = Label.new()
	about.text = "NostrGD Client\nGodot 4 + .NET 8 + Nostr SDK"
	about.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(about)

	vbox.add_child(HSeparator.new())

	var disconnect_btn = Button.new()
	disconnect_btn.text = "🔌 切断してログアウト"
	disconnect_btn.pressed.connect(_on_disconnect_button_pressed)
	vbox.add_child(disconnect_btn)

func _refresh_settings_relays() -> void:
	var panel = $MainPanel/SettingsPanel
	var list_vbox = panel.get_node_or_null("SettingsScroll/SettingsMargin/SettingsVBox/SettingsRelayList")
	if list_vbox == null:
		return
	for child in list_vbox.get_children():
		child.queue_free()
	for url in RELAY_URL:
		_add_relay_row(list_vbox, url)

func _add_relay_row(parent: VBoxContainer, url: String) -> void:
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(row)

	var label = Label.new()
	label.text = "  • " + url
	label.add_theme_color_override("font_color", Color(0.5, 0.7, 1))
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)

	var remove_btn = Button.new()
	remove_btn.text = "✕"
	remove_btn.custom_minimum_size = Vector2(28, 24)
	remove_btn.add_theme_color_override("font_color", Color(1, 0.4, 0.4))
	remove_btn.pressed.connect(func():
		NostrGD.DisconnectFromRelay(url)
		RELAY_URL.erase(url)
		NostrGD.SaveRelayUrls(RELAY_URL)
		_refresh_settings_relays()
		_reset_timeline()
		status_label.text = "リレーを削除しました: " + url
	)
	row.add_child(remove_btn)

func _switch_section(section: int) -> void:
	_current_section = section

	if _ui_state == UIState.CREATE_FORM and NostrGD.IsLoggedIn:
		_is_profile_edit = false
		_ui_state = UIState.LOGGED_IN
		auth_choice_hbox.visible = false
		login_container.visible = false
		create_container.visible = false
		logged_in_container.visible = true
		$Sidebar/SidebarInner/AccountSection/VBoxContainer/ExtensionLogin.visible = false
		var confirm_btn = $Sidebar/SidebarInner/AccountSection/VBoxContainer/CreateContainer/CreateBtnHBox/CreateConfirmBtn
		if confirm_btn and is_instance_valid(confirm_btn):
			confirm_btn.text = "作成"

	$MainPanel/ScrollContainer.hide()
	$MainPanel/NotificationsPanel.hide()
	$MainPanel/DMPanel.hide()
	$MainPanel/ProfilePanel.hide()
	$MainPanel/SettingsPanel.hide()

	var names = {
		Section.TIMELINE: "🌐  タイムライン",
		Section.NOTIFICATIONS: "🔔  通知",
		Section.DM: "💬  DM",
		Section.PROFILE: "👤  プロフィール",
		Section.SETTINGS: "⚙️  設定"
	}
	section_header.text = names.get(section, "セクション")

	match section:
		Section.TIMELINE:
			$MainPanel/ScrollContainer.show()
			$MainPanel/InputBar.visible = (_ui_state == UIState.LOGGED_IN)
		Section.NOTIFICATIONS:
			$MainPanel/NotificationsPanel.show()
			$MainPanel/InputBar.hide()
			_refresh_notifications()
		Section.DM:
			$MainPanel/DMPanel.show()
			$MainPanel/InputBar.hide()
			_refresh_dms()
		Section.PROFILE:
			$MainPanel/ProfilePanel.show()
			$MainPanel/InputBar.hide()
			_refresh_profile()
		Section.SETTINGS:
			$MainPanel/SettingsPanel.show()
			$MainPanel/InputBar.hide()

	_update_nav_highlight()

func _refresh_profile() -> void:
	var panel = $MainPanel/ProfilePanel
	var name_label = panel.get_node_or_null("ProfileScroll/ProfileMargin/ProfileVBox/ProfileHeader/ProfileNameSection/ProfileName")
	if name_label == null:
		for c in panel.get_children():
			panel.remove_child(c)
			c.free()
		var banner = TextureRect.new()
		banner.name = "ProfileBanner"
		banner.custom_minimum_size = Vector2(0, 200)
		banner.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		banner.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		banner.clip_contents = true
		panel.add_child(banner)
		var scroll = ScrollContainer.new()
		scroll.name = "ProfileScroll"
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		panel.add_child(scroll)
		var margin = MarginContainer.new()
		margin.name = "ProfileMargin"
		margin.add_theme_constant_override("margin_left", 16)
		margin.add_theme_constant_override("margin_right", 16)
		margin.add_theme_constant_override("margin_top", 16)
		margin.add_theme_constant_override("margin_bottom", 16)
		margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(margin)
		var vbox = VBoxContainer.new()
		vbox.name = "ProfileVBox"
		vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_theme_constant_override("separation", 8)
		margin.add_child(vbox)
		var hbox = HBoxContainer.new()
		hbox.name = "ProfileHeader"
		hbox.add_theme_constant_override("separation", 16)
		vbox.add_child(hbox)
		var arect = TextureRect.new()
		arect.name = "ProfileAvatar"
		arect.custom_minimum_size = Vector2(80, 80)
		arect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		arect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		arect.clip_contents = true
		arect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		arect.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		hbox.add_child(arect)
		var nvbox = VBoxContainer.new()
		nvbox.name = "ProfileNameSection"
		nvbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nvbox.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		hbox.add_child(nvbox)
		var nl = Label.new()
		nl.name = "ProfileName"
		nl.add_theme_font_size_override("font_size", 22)
		nvbox.add_child(nl)
		var al = Label.new()
		al.name = "ProfileAbout"
		al.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		al.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
		nvbox.add_child(al)
		var pl = Label.new()
		pl.name = "ProfilePubkey"
		pl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		pl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vbox.add_child(pl)
		var ll = Label.new()
		ll.name = "ProfileLud"
		ll.add_theme_color_override("font_color", Color(0.5, 0.7, 1))
		vbox.add_child(ll)
		var eb = Button.new()
		eb.text = "プロフィールを編集"
		eb.pressed.connect(_on_profile_edit)
		vbox.add_child(eb)
		var cb = Button.new()
		cb.text = "Pubkey をコピー"
		cb.pressed.connect(func():
			DisplayServer.clipboard_set(NostrGD.GetPublicKeyHex())
			status_label.text = "Pubkey をコピーしました"
		)
		vbox.add_child(cb)
		name_label = panel.get_node("ProfileScroll/ProfileMargin/ProfileVBox/ProfileHeader/ProfileNameSection/ProfileName")
	var name_vbox = panel.get_node("ProfileScroll/ProfileMargin/ProfileVBox/ProfileHeader/ProfileNameSection")
	var about_label = name_vbox.get_node("ProfileAbout")
	var pubkey_label = panel.get_node("ProfileScroll/ProfileMargin/ProfileVBox/ProfilePubkey")
	var lud_label = panel.get_node("ProfileScroll/ProfileMargin/ProfileVBox/ProfileLud")
	var avatar_rect = panel.get_node("ProfileScroll/ProfileMargin/ProfileVBox/ProfileHeader/ProfileAvatar")
	var banner_rect = panel.get_node_or_null("ProfileBanner")

	if not NostrGD.IsLoggedIn:
		name_label.text = "ログインが必要です"
		return
	var pubkey = NostrGD.GetPublicKeyHex()
	var profile = profile_cache.get(pubkey, {})
	if not profile is Dictionary or profile.is_empty():
		name_label.text = "プロフィールを読み込み中..."
		pubkey_label.text = "Pubkey: " + pubkey
		if not pubkey_request_pool.has(pubkey):
			pubkey_request_pool.append(pubkey)
		return

	name_label.text = profile.get("display_name", profile.get("name", "Unknown"))
	about_label.text = profile.get("about", "")
	pubkey_label.text = "Pubkey: " + pubkey
	lud_label.text = "⚡ " + profile.get("lud16", "") if profile.get("lud16", "") != "" else ""

	var avatar_url = profile.get("picture", "")
	if avatar_url != "":
		_load_and_apply_avatar(avatar_url, avatar_rect)

	var banner_url = profile.get("banner", "")
	if banner_url != "" and banner_rect != null:
		_load_and_apply_banner(banner_url, banner_rect)

func _on_profile_edit() -> void:
	_is_profile_edit = true
	_set_ui_state(UIState.CREATE_FORM)
	var profile = profile_cache.get(NostrGD.GetPublicKeyHex(), {})
	if profile is Dictionary:
		var name = profile.get("name", "")
		if name.begins_with("@"):
			register_name_input.text = name
		else:
			register_name_input.text = "@" + name
		register_display_input.text = profile.get("display_name", "")
		register_picture_input.text = profile.get("picture", "")
		register_banner_input.text = profile.get("banner", "")
		register_lud16_input.text = profile.get("lud16", "")
	$Sidebar/SidebarInner/AccountSection/VBoxContainer/CreateContainer/CreateBtnHBox/CreateConfirmBtn.text = "更新"

func _update_nav_highlight() -> void:
	for i in nav_buttons.size():
		var btn = nav_buttons[i]
		if i == _current_section:
			btn.add_theme_color_override("font_color", Color(1, 1, 1))
			var bg = StyleBoxFlat.new()
			bg.bg_color = Color(0.25, 0.45, 0.7, 0.3)
			btn.add_theme_stylebox_override("normal", bg)
		else:
			btn.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
			var bg = StyleBoxFlat.new()
			bg.bg_color = Color(0, 0, 0, 0)
			btn.add_theme_stylebox_override("normal", bg)

func _on_nav_timeline() -> void:
	_switch_section(Section.TIMELINE)

func _on_nav_notifications() -> void:
	_switch_section(Section.NOTIFICATIONS)

func _on_nav_dm() -> void:
	_switch_section(Section.DM)

func _on_nav_profile() -> void:
	_switch_section(Section.PROFILE)

func _on_nav_settings() -> void:
	_switch_section(Section.SETTINGS)

func _on_nostr_notice(url: String, message: String) -> void:
	print("[%s]からの通知: %s" % [url, message])

func _on_nostr_event_received(subscription_id: String, event_dict: Dictionary) -> void:
	match subscription_id:
		"profile_resolver":
			_parse_profile_event(event_dict)
		_:
			if event_dict.has("kind") and event_dict["kind"] == 0:
				_parse_profile_event(event_dict)
			elif subscription_id.begins_with("embed_"):
				_handle_embed_response(event_dict)
			elif subscription_id.begins_with("notif_embed_"):
				_handle_notif_embed_response(event_dict)
			elif not _notification_sub_id.is_empty() and subscription_id == _notification_sub_id:
				_notifications_events.append(event_dict)
				while _notifications_events.size() > MAX_NOTIFICATIONS:
					_notifications_events.pop_front()
				if _current_section == Section.NOTIFICATIONS:
					_refresh_notifications()
			elif not _dm_sub_id.is_empty() and subscription_id == _dm_sub_id:
				_on_nostr_direct_message("", subscription_id, event_dict)

func _setup_stamp_popup() -> void:
	var popup = PopupPanel.new()
	popup.name = "StampPopup"
	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	var grid = GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	for emoji in ["👍", "❤️", "😂", "🎉", "🔥", "😢", "😡", "💯", "🚀", "👀"]:
		var btn = Button.new()
		btn.text = emoji
		btn.custom_minimum_size = Vector2(40, 36)
		btn.pressed.connect(_on_stamp_selected.bind(emoji))
		grid.add_child(btn)
	margin.add_child(grid)
	popup.add_child(margin)
	add_child(popup)

func _on_stamp_selected(emoji: String) -> void:
	if _stamp_event_id.is_empty() or not NostrGD.IsLoggedIn:
		return
	NostrGD.SendReaction(_stamp_event_id, _stamp_pubkey, emoji)
	_stamp_event_id = ""
	_stamp_pubkey = ""
	$StampPopup.hide()

func _setup_zap_popup() -> void:
	var popup = PopupPanel.new()
	popup.name = "ZapPopup"
	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)

	var amount_label = Label.new()
	amount_label.text = "Zap 金額 (sats)"
	vbox.add_child(amount_label)
	_zap_amount_input = LineEdit.new()
	_zap_amount_input.placeholder_text = "1"
	vbox.add_child(_zap_amount_input)

	var msg_label = Label.new()
	msg_label.text = "メッセージ (任意)"
	vbox.add_child(msg_label)
	_zap_msg_input = LineEdit.new()
	_zap_msg_input.placeholder_text = "コメント..."
	vbox.add_child(_zap_msg_input)

	var btn_hbox = HBoxContainer.new()
	btn_hbox.add_theme_constant_override("separation", 8)
	var send_btn = Button.new()
	send_btn.text = "送信"
	send_btn.pressed.connect(_on_zap_send)
	btn_hbox.add_child(send_btn)
	var cancel_btn = Button.new()
	cancel_btn.text = "キャンセル"
	cancel_btn.pressed.connect(func(): $ZapPopup.hide())
	btn_hbox.add_child(cancel_btn)
	vbox.add_child(btn_hbox)

	margin.add_child(vbox)
	popup.add_child(margin)
	add_child(popup)

func _on_zap_send() -> void:
	if _zap_event_id.is_empty() or not NostrGD.IsLoggedIn or _zap_in_progress:
		return
	_zap_in_progress = true
	var amount_str = _zap_amount_input.text.strip_edges()
	var msg = _zap_msg_input.text.strip_edges()
	var amount_sats = int(amount_str) if amount_str.is_valid_int() else 1
	$ZapPopup.hide()

	var profile = profile_cache.get(_zap_pubkey, {})
	if not profile is Dictionary:
		status_label.text = "エラー: プロフィールが見つかりません"
		_zap_in_progress = false
		return

	var lnurl_url = NostrUtils.resolve_lnurl(profile)
	if lnurl_url.is_empty():
		status_label.text = "エラー: LNURL を解決できません"
		_zap_in_progress = false
		return

	status_label.text = "LNURL エンドポイントを取得中..."
	var params = await _http_get_json(lnurl_url)
	if params.is_empty():
		_zap_in_progress = false
		return

	var callback = params.get("callback", "")
	if callback.is_empty():
		status_label.text = "エラー: callback URL が見つかりません"
		_zap_in_progress = false
		return

	status_label.text = "Zap リクエストを作成中..."
	var zap_request = NostrGD.CreateZapRequestEvent(_zap_event_id, _zap_pubkey, amount_sats * 1000, msg, RELAY_URL)

	status_label.text = "インボイスをリクエスト中..."
	var zap_json = JSON.stringify(zap_request)
	var callback_full = callback + "?amount=" + str(amount_sats * 1000) + "&nostr=" + zap_json.uri_encode()
	var invoice_data = await _http_get_json(callback_full)
	if invoice_data.is_empty():
		_zap_in_progress = false
		return

	var invoice = invoice_data.get("pr", "")
	if invoice.is_empty():
		status_label.text = "エラー: インボイスが取得できませんでした"
		_zap_in_progress = false
		return

	if NostrGD.IsNwcConfigured:
		var wallet_pk = NostrGD.NwcWalletPubkey
		print("NWC: sending pay_invoice to ", wallet_pk)
		var sent = NostrGD.NWCPayInvoice(invoice, wallet_pk)
		if sent:
			status_label.text = "⚡ NWC 経由で Zap を送信しました"
			print("NWC: pay_invoice sent successfully")
		else:
			status_label.text = "エラー: NWC コマンドの送信に失敗しました"
			print("NWC: pay_invoice FAILED")
	else:
		_show_invoice(invoice, amount_sats)
		status_label.text = "⚡ Lightning インボイスを受信しました。ウォレットで支払ってください。"
	_zap_event_id = ""
	_zap_pubkey = ""
	_zap_in_progress = false

func _http_get_json(url: String) -> Dictionary:
	var http = HTTPRequest.new()
	add_child(http)
	http.request(url)
	var signal_data = await http.request_completed
	http.queue_free()

	if signal_data.size() < 4:
		return {}
	var result = signal_data[0]
	var response_code = signal_data[1]
	var body = signal_data[3]

	if result != HTTPRequest.RESULT_SUCCESS:
		status_label.text = "HTTP エラー: %d" % result
		return {}

	if response_code != 200:
		status_label.text = "HTTP ステータスエラー: %d" % response_code
		return {}

	var json = JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		status_label.text = "JSON パースエラー"
		return {}

	return json.get_data()

func _setup_invoice_popup() -> void:
	var popup = PopupPanel.new()
	popup.name = "InvoicePopup"
	add_child(popup)

	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	popup.add_child(margin)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	var title = Label.new()
	title.text = "⚡ Lightning Invoice"
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)

	_invoice_qr_rect = TextureRect.new()
	_invoice_qr_rect.custom_minimum_size = Vector2(250, 250)
	_invoice_qr_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_invoice_qr_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	vbox.add_child(_invoice_qr_rect)

	_invoice_label = Label.new()
	_invoice_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_invoice_label.max_lines_visible = 4
	vbox.add_child(_invoice_label)

	var btn_hbox = HBoxContainer.new()
	btn_hbox.add_theme_constant_override("separation", 8)
	var copy_btn = Button.new()
	copy_btn.text = "コピー"
	copy_btn.pressed.connect(func():
		DisplayServer.clipboard_set(_invoice_label.text)
		status_label.text = "インボイスをコピーしました"
	)
	btn_hbox.add_child(copy_btn)
	var close_btn = Button.new()
	close_btn.text = "閉じる"
	close_btn.pressed.connect(func(): $InvoicePopup.hide())
	btn_hbox.add_child(close_btn)
	vbox.add_child(btn_hbox)

func _show_invoice(invoice: String, amount_sats: int) -> void:
	_invoice_label.text = invoice

	var qr_url = "https://api.qrserver.com/v1/create-qr-code/?size=250x250&data="
	qr_url += ("lightning:" + invoice).uri_encode()
	_load_invoice_qr(qr_url)

	$InvoicePopup.popup_centered(Vector2(320, 420))

func _load_invoice_qr(url: String) -> void:
	var http = HTTPRequest.new()
	add_child(http)

	var callback = func(result, response_code, _headers, body, rect):
		if not is_instance_valid(rect):
			return
		if result == HTTPRequest.RESULT_SUCCESS and response_code == 200:
			var image = Image.new()
			var error = image.load_png_from_buffer(body)
			if error != OK:
				error = image.load_jpg_from_buffer(body)
			if error != OK:
				error = image.load_webp_from_buffer(body)
			if error == OK and is_instance_valid(rect):
				rect.texture = ImageTexture.create_from_image(image)
		if is_instance_valid(http):
			http.queue_free()

	http.request_completed.connect(callback.bind(_invoice_qr_rect))
	var err = http.request(url)
	if err != OK:
		http.queue_free()

func _on_nostr_timeline_updated(sorted_timeline: Array) -> void:
	_pending_sorted_timeline = sorted_timeline
	if not _timeline_update_timer.is_processing():
		_timeline_update_timer.start()

func _on_nostr_nwc_response(_url: String, _subscription_id: String, _event_dict: Dictionary) -> void:
	status_label.text = "⚡ NWC レスポンスを受信しました"

func _on_timeline_scrolled(value: float) -> void:
	if _current_section != Section.TIMELINE:
		return
	var scroll = $MainPanel/ScrollContainer
	var max_val = scroll.get_v_scroll_bar().max_value
	if max_val <= 0:
		return
	var at_bottom = value >= max_val - 10
	if at_bottom and not _timeline_paused:
		_pause_timeline()
	elif not at_bottom and _timeline_paused:
		_resume_timeline()

func _pause_timeline() -> void:
	_timeline_paused = true
	status_label.text = "タイムライン一時停止中"
	NostrGD.CloseSubscription("global_feed")

func _reset_timeline() -> void:
	_timeline_paused = false
	NostrGD.CloseSubscription("global_feed")
	NostrGD.ClearTimeline()
	_pending_sorted_timeline = []
	for child in timeline.get_children():
		child.queue_free()
	pending_labels.clear()
	_zap_buttons_by_pubkey.clear()
	_pending_embeds.clear()
	for url in RELAY_URL:
		NostrGD.RequestTimeline("global_feed", 20, url)

func _resume_timeline() -> void:
	_timeline_paused = false
	status_label.text = "タイムライン再開"
	for url in RELAY_URL:
		NostrGD.RequestTimeline("global_feed", 20, url)

func _apply_timeline_update() -> void:
	var events = _pending_sorted_timeline
	_pending_sorted_timeline = []

	for child in timeline.get_children():
		child.queue_free()

	pending_labels.clear()
	_zap_buttons_by_pubkey.clear()
	_pending_embeds.clear()

	var count = 0
	for event in events:
		if count >= TIMELINE_MAX_ITEMS:
			break
		_rebuild_timeline_item(event)
		count += 1

func _on_extension_auth_completed():
	_set_ui_state(UIState.LOGGED_IN)
	status_label.text = "拡張認証完了"

func _on_create_account_button_pressed() -> void:
	var user_name = register_name_input.text.strip_edges()
	var display_name = register_display_input.text.strip_edges()

	if user_name.is_empty() or display_name.is_empty():
		status_label.text = "エラー: ユーザー名と表示名を入力してください"
		return

	if _is_profile_edit:
		_is_profile_edit = false
		$Sidebar/SidebarInner/AccountSection/VBoxContainer/CreateContainer/CreateBtnHBox/CreateConfirmBtn.text = "作成"
		NostrGD.SendProfileMetaData(
			user_name, display_name, "Multi-relay test",
			register_picture_input.text.strip_edges(),
			register_banner_input.text.strip_edges(),
			register_lud16_input.text.strip_edges()
		)
		_set_ui_state(UIState.LOGGED_IN)
		_switch_section(Section.PROFILE)
		status_label.text = "プロフィールを更新しました"
		return

	var new_private_key_nsec: String = NostrGD.CreateNewKeyPair()
	if not new_private_key_nsec.is_empty():
		private_key_input.text = new_private_key_nsec
		_save_private_key(new_private_key_nsec)

		var hex_key: String = NostrGD.GetPrivateKeyHex()
		var pubkey_hex: String = NostrGD.GetPublicKeyHex()
		var nsec_key: String = NostrGD.GetPrivateKeyNsec()
		DisplayServer.clipboard_set(nsec_key)
		status_label.text = "新しいアカウントを作成しました！\n"
		status_label.text += "【重要】秘密鍵(nsec)をクリップボードにコピーしました\n"
		status_label.text += "Hex: " + hex_key + "\n"
		status_label.text += "nsec: " + nsec_key

		_connect_relays()
		_set_ui_state(UIState.LOGGED_IN)

		NostrGD.SendProfileMetaData(
			user_name,
			display_name,
			"Multi-relay test",
			register_picture_input.text.strip_edges(),
			register_banner_input.text.strip_edges(),
			register_lud16_input.text.strip_edges()
		)

		profile_cache[NostrGD.GetPublicKeyHex()] = {
			"name": user_name,
			"display_name": display_name,
			"picture": register_picture_input.text.strip_edges(),
			"banner": register_banner_input.text.strip_edges(),
			"lud16": register_lud16_input.text.strip_edges()
		}

		if not pool_timer.is_processing():
			pool_timer.start()
	else:
		status_label.text = "アカウントの作成に失敗しました"

func _on_login_button_pressed() -> void:
	var key_input_text = private_key_input.text.strip_edges()
	if key_input_text.is_empty():
		status_label.text = "エラー: 鍵が空です"
		return

	if NostrGD.Login(key_input_text):
		_save_private_key(key_input_text)
		_connect_relays()
		_set_ui_state(UIState.LOGGED_IN)
		status_label.text = "ログイン完了"
	else:
		status_label.text = "エラー: 無効な秘密鍵(Hexまたはnsec)です"

func _on_extension_login_button_pressed() -> void:
	status_label.text = "ブラウザを起動してローカル認証中..."
	NostrGD.StartLocalAuthServer()

func _on_disconnect_button_pressed() -> void:
	_timeline_paused = false
	NostrGD.CloseSubscription("global_feed")
	NostrGD.ClearTimeline()
	_pending_sorted_timeline = []
	for child in timeline.get_children():
		child.queue_free()
	pending_labels.clear()
	_zap_buttons_by_pubkey.clear()
	_pending_embeds.clear()
	for relay_url in RELAY_URL:
		NostrGD.DisconnectFromRelay(relay_url)
	_set_ui_state(UIState.LOGGED_OUT)
	status_label.text = "切断しました"

func _on_send_button_pressed() -> void:
	var content = message_input.text.strip_edges()
	if content.is_empty() or not NostrGD.IsLoggedIn:
		return
	if _reply_context.has("event_id"):
		NostrGD.SendReply(content, _reply_context["event_id"], _reply_context["pubkey"])
		_reply_context = {}
		_set_input_placeholder("")
	else:
		NostrGD.SendTextNote(content)
	message_input.clear()
	_reply_context_label.visible = false

func _set_input_placeholder(text: String) -> void:
	message_input.placeholder_text = text

func _on_reply_button(event_id: String, pubkey: String, name: String, content: String) -> void:
	_reply_context = { "event_id": event_id, "pubkey": pubkey }
	message_input.grab_focus()
	_set_input_placeholder(name + " に返信... (Escでキャンセル)")
	_reply_context_label.text = "返信先: " + name + ": " + content.left(80)
	_reply_context_label.visible = true

func _on_repost_button(event_id: String) -> void:
	if not NostrGD.IsLoggedIn:
		return
	NostrGD.SendRepost(event_id)
	status_label.text = "リポストしました"

func _start_notification_subscription() -> void:
	if _notification_sub_id.is_empty() or not NostrGD.IsLoggedIn:
		return
	var pubkey = NostrGD.GetPublicKeyHex()
	NostrGD.RequestNotifications(_notification_sub_id, pubkey)

func _refresh_notifications() -> void:
	var notif_panel = $MainPanel/NotificationsPanel
	var list_vbox = notif_panel.get_node_or_null("NotifScroll/NotifList")
	if list_vbox == null:
		_build_notifications_section()
		list_vbox = notif_panel.get_node("NotifScroll/NotifList")
	for child in list_vbox.get_children():
		child.queue_free()

	while _notifications_events.size() > MAX_NOTIFICATIONS:
		_notifications_events.pop_back()

	_notifications_events.sort_custom(func(a, b):
		return a.get("created_at", 0) > b.get("created_at", 0)
	)

	if _notifications_events.is_empty():
		var empty_label = Label.new()
		empty_label.text = "通知はありません"
		empty_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		list_vbox.add_child(empty_label)
		return

	for ev in _notifications_events:
		var kind = ev.get("kind", 0)
		var pubkey = ev.get("pubkey", "")
		var content = ev.get("content", "")
		var tags = ev.get("tags", [])
		var ref_event_id = ""
		for t in tags:
			if t is Array and t.size() >= 2 and t[0] == "e" and t[1] is String:
				ref_event_id = t[1]
				break

		var card = PanelContainer.new()
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var s = StyleBoxFlat.new()
		s.bg_color = Color(0.1, 0.11, 0.13)
		s.content_margin_left = 14
		s.content_margin_right = 14
		s.content_margin_top = 10
		s.content_margin_bottom = 10
		card.add_theme_stylebox_override("panel", s)
		list_vbox.add_child(card)

		var vbox = VBoxContainer.new()
		vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_theme_constant_override("separation", 4)
		card.add_child(vbox)

		var reactor_hbox = HBoxContainer.new()
		reactor_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		reactor_hbox.add_theme_constant_override("separation", 6)
		vbox.add_child(reactor_hbox)

		var avatar_rect = TextureRect.new()
		avatar_rect.custom_minimum_size = Vector2(24, 24)
		avatar_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		avatar_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		avatar_rect.clip_contents = true
		avatar_rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		reactor_hbox.add_child(avatar_rect)

		var reactor_name = pubkey.left(12) + "..."
		if profile_cache.has(pubkey) and profile_cache[pubkey] is Dictionary:
			reactor_name = profile_cache[pubkey].get("display_name", profile_cache[pubkey].get("name", reactor_name))
		var reactor_label = Label.new()
		reactor_label.text = reactor_name
		reactor_label.add_theme_color_override("font_color", Color.GREEN_YELLOW)
		reactor_label.add_theme_font_size_override("font_size", 12)
		reactor_hbox.add_child(reactor_label)

		var kind_str = ""
		var kind_color = Color(0.5, 0.5, 0.6)
		match kind:
			7:
				kind_str = "リアクションしました"
				kind_color = Color(1, 0.6, 0.6)
			6, 16:
				kind_str = "リポストしました"
				kind_color = Color(0.4, 0.8, 0.6)
			9735:
				kind_str = "Zap: " + str(ev.get("amount", ev.get("content", "?"))) + " sats"
				kind_color = Color(1, 0.8, 0.4)
		var kind_label = Label.new()
		kind_label.text = kind_str
		kind_label.add_theme_color_override("font_color", kind_color)
		kind_label.add_theme_font_size_override("font_size", 11)
		reactor_hbox.add_child(kind_label)

		if kind == 7:
			var raw = content.strip_edges()
			if raw not in ["+", "-", ""]:
				var emoji_url = NostrUtils.resolve_custom_emoji(content, tags)
				if emoji_url != "":
					var emoji_rect = TextureRect.new()
					emoji_rect.custom_minimum_size = Vector2(22, 22)
					emoji_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
					emoji_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
					emoji_rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
					reactor_hbox.add_child(emoji_rect)
					_load_and_apply_avatar(emoji_url, emoji_rect)
				else:
					var emoji_label = Label.new()
					emoji_label.text = raw
					emoji_label.add_theme_font_size_override("font_size", 16)
					reactor_hbox.add_child(emoji_label)

		if profile_cache.has(pubkey) and profile_cache[pubkey] is Dictionary:
			var avatar_url = profile_cache[pubkey].get("picture", "")
			if avatar_url != "":
				_load_and_apply_avatar(avatar_url, avatar_rect)
		elif not pubkey_request_pool.has(pubkey):
			pubkey_request_pool.append(pubkey)

		if ref_event_id != "":
			var nested_panel = PanelContainer.new()
			var ns = StyleBoxFlat.new()
			ns.bg_color = Color(0.05, 0.06, 0.08)
			ns.set_border_width_all(1)
			ns.border_color = Color(0.2, 0.22, 0.25)
			ns.corner_radius_top_left = 4
			ns.corner_radius_top_right = 4
			ns.corner_radius_bottom_right = 4
			ns.corner_radius_bottom_left = 4
			ns.content_margin_left = 8
			ns.content_margin_right = 8
			ns.content_margin_top = 6
			ns.content_margin_bottom = 6
			nested_panel.add_theme_stylebox_override("panel", ns)
			vbox.add_child(nested_panel)

			var nested_vbox = VBoxContainer.new()
			nested_vbox.add_theme_constant_override("separation", 4)
			nested_panel.add_child(nested_vbox)

			var loading_label = Label.new()
			loading_label.text = "読み込み中..."
			loading_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
			loading_label.add_theme_font_size_override("font_size", 11)
			nested_vbox.add_child(loading_label)

			if not _pending_notif_embeds.has(ref_event_id):
				_pending_notif_embeds[ref_event_id] = []
			_pending_notif_embeds[ref_event_id].append(nested_vbox)

			var embed_sub_id = "notif_embed_" + ref_event_id.left(8)
			NostrGD.RequestEventById(ref_event_id, embed_sub_id)

func _start_dm_subscription() -> void:
	if _dm_sub_id.is_empty() or not NostrGD.IsLoggedIn:
		return
	var pubkey = NostrGD.GetPublicKeyHex()
	NostrGD.RequestDirectMessages(_dm_sub_id, pubkey)

func _on_nostr_direct_message(url: String, subscription_id: String, event_dict: Dictionary) -> void:
	var sender = event_dict.get("pubkey", "")
	if sender.is_empty():
		return
	if not _dm_conversations.has(sender):
		_dm_conversations[sender] = []
	_dm_conversations[sender].append(event_dict)

	if _current_section == Section.DM:
		_refresh_dms()

func _refresh_dms() -> void:
	var list_vbox = $MainPanel/DMPanel/DMScroll/DMList
	for child in list_vbox.get_children():
		child.queue_free()

	if _dm_conversations.is_empty():
		var empty_label = Label.new()
		empty_label.text = "DMはありません"
		empty_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		list_vbox.add_child(empty_label)
		return

	for sender in _dm_conversations:
		var msgs = _dm_conversations[sender]
		var name_str = sender.left(12) + "..."
		if profile_cache.has(sender) and profile_cache[sender] is Dictionary:
			name_str = profile_cache[sender].get("display_name", profile_cache[sender].get("name", name_str))

		var header = Label.new()
		header.text = "--- " + name_str + " ---"
		header.add_theme_color_override("font_color", Color(0.5, 0.7, 1))
		list_vbox.add_child(header)

		for msg in msgs:
			var content = msg.get("content", "")
			var time = msg.get("created_at", 0)
			var time_str = "[" + Time.get_datetime_string_from_unix_time(time, true) + "]"

			var msg_label = Label.new()
			msg_label.text = time_str + " " + content
			msg_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			msg_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.85))
			list_vbox.add_child(msg_label)

func _on_dm_send() -> void:
	if not NostrGD.IsLoggedIn:
		return
	var target = $MainPanel/DMPanel/DMInputBar/DMPubkey.text.strip_edges()
	var content = $MainPanel/DMPanel/DMInputBar/DMMessage.text.strip_edges()
	if content.is_empty() or target.is_empty():
		return
	NostrGD.SendDirectMessage(content, target)
	$MainPanel/DMPanel/DMInputBar/DMMessage.clear()
	status_label.text = "DMを送信しました"

func _on_image_upload_button() -> void:
	if _file_dialog == null or not is_instance_valid(_file_dialog):
		_file_dialog = FileDialog.new()
		_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_file_dialog.add_filter("*.png,*.jpg,*.jpeg,*.gif,*.webp", "画像ファイル")
		_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_file_dialog.file_selected.connect(_on_image_file_selected)
		add_child(_file_dialog)
	_file_dialog.popup_centered(Vector2(600, 400))

func _on_image_file_selected(path: String) -> void:
	status_label.text = "画像をアップロード中..."
	var http = HTTPRequest.new()
	add_child(http)

	var callback = func(result, response_code, headers, body):
		if result == HTTPRequest.RESULT_SUCCESS and response_code == 200:
			var json = JSON.new()
			if json.parse(body.get_string_from_utf8()) == OK:
				var data = json.get_data()
				var url = ""
				if data is Dictionary:
					if data.has("url"):
						url = data["url"]
					elif data.has("data") and data["data"] is Dictionary and data["data"].has("url"):
						url = data["data"]["url"]
				if not url.is_empty():
					var current_text = message_input.text
					if not current_text.is_empty():
						current_text += "\n"
					message_input.text = current_text + url
					status_label.text = "画像URLを挿入しました"
					return
			status_label.text = "URLが取得できませんでした。手動でURLを貼ってください。"
		else:
			status_label.text = "アップロード失敗(" + str(response_code) + ")。手動で画像URLを貼ってください。"
		if is_instance_valid(http):
			http.queue_free()

	http.request_completed.connect(callback)

	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		status_label.text = "ファイルを開けませんでした"
		http.queue_free()
		return

	var buffer = file.get_buffer(file.get_length())
	var b64 = Marshalls.raw_to_base64(buffer)
	var ext = path.get_extension().to_lower()

	var boundary = "----NostrGD" + str(Time.get_unix_time_from_system())
	var header_str = "--" + boundary + "\r\n"
	header_str += "Content-Disposition: form-data; name=\"image\"; filename=\"upload." + ext + "\"\r\n"
	header_str += "Content-Type: image/" + ext + "\r\n\r\n"
	var footer_str = "\r\n--" + boundary + "--\r\n"

	var header_bytes = header_str.to_utf8_buffer()
	var footer_bytes = footer_str.to_utf8_buffer()

	var body = PackedByteArray()
	body.append_array(header_bytes)
	body.append_array(buffer)
	body.append_array(footer_bytes)

	var content_type = "Content-Type: multipart/form-data; boundary=" + boundary
	var error = http.request("https://nostr.build/api/upload.php", [content_type], HTTPClient.METHOD_POST, body)
	if error != OK:
		status_label.text = "アップロードリクエスト失敗"
		http.queue_free()

func _on_reaction(event_id: String, target_pubkey: String, emoji: String) -> void:
	if not NostrGD.IsLoggedIn:
		return
	NostrGD.SendReaction(event_id, target_pubkey, emoji)

func _on_like_toggle(event_id: String, target_pubkey: String, btn: Button) -> void:
	if not NostrGD.IsLoggedIn:
		return
	if _liked_events.has(event_id):
		NostrGD.SendReaction(event_id, target_pubkey, "-")
		_liked_events.erase(event_id)
		btn.text = "🩶"
		btn.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	else:
		NostrGD.SendReaction(event_id, target_pubkey, "❤️")
		_liked_events[event_id] = true
		btn.text = "❤️"
		btn.add_theme_color_override("font_color", Color(1, 0.2, 0.2))

func _open_stamp(event_id: String, pubkey: String) -> void:
	_stamp_event_id = event_id
	_stamp_pubkey = pubkey
	$StampPopup.popup_centered(Vector2(280, 200))

func _on_zap(event_id: String, target_pubkey: String) -> void:
	if not NostrGD.IsLoggedIn:
		return
	_zap_event_id = event_id
	_zap_pubkey = target_pubkey
	_zap_amount_input.text = ""
	_zap_msg_input.text = ""
	$ZapPopup.popup_centered(Vector2(300, 220))

func _handle_embed_response(event_dict: Dictionary) -> void:
	var embed_id = event_dict.get("id", "")
	if embed_id.is_empty() or not _pending_embeds.has(embed_id):
		return

	var embed_data = _pending_embeds[embed_id]
	var nested_vbox = embed_data.get("nested_vbox", null)
	if not is_instance_valid(nested_vbox):
		_pending_embeds.erase(embed_id)
		return

	for child in nested_vbox.get_children():
		child.queue_free()

	var embed_content = event_dict.get("content", "")
	var embed_pubkey = event_dict.get("pubkey", "")

	var name_str = embed_pubkey.left(12) + "..."
	if profile_cache.has(embed_pubkey) and profile_cache[embed_pubkey] is Dictionary:
		name_str = profile_cache[embed_pubkey].get("display_name", profile_cache[embed_pubkey].get("name", name_str))

	var name_label = Label.new()
	name_label.text = name_str
	name_label.add_theme_color_override("font_color", Color.GREEN_YELLOW)
	name_label.add_theme_font_size_override("font_size", 11)
	nested_vbox.add_child(name_label)

	var content_label = Label.new()
	content_label.text = embed_content
	content_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.85))
	content_label.add_theme_font_size_override("font_size", 12)
	nested_vbox.add_child(content_label)

	_pending_embeds.erase(embed_id)

func _handle_notif_embed_response(event_dict: Dictionary) -> void:
	var embed_id = event_dict.get("id", "")
	if embed_id.is_empty() or not _pending_notif_embeds.has(embed_id):
		return
	var targets = _pending_notif_embeds[embed_id]
	_pending_notif_embeds.erase(embed_id)
	var embed_content = event_dict.get("content", "")
	var embed_pubkey = event_dict.get("pubkey", "")
	var embed_name = embed_pubkey.left(12) + "..."
	if profile_cache.has(embed_pubkey) and profile_cache[embed_pubkey] is Dictionary:
		embed_name = profile_cache[embed_pubkey].get("display_name", profile_cache[embed_pubkey].get("name", embed_name))
	for nvbox in targets:
		if not is_instance_valid(nvbox):
			continue
		for child in nvbox.get_children():
			child.queue_free()
		var nl = Label.new()
		nl.text = embed_name
		nl.add_theme_color_override("font_color", Color.GREEN_YELLOW)
		nl.add_theme_font_size_override("font_size", 11)
		nvbox.add_child(nl)
		var cl = Label.new()
		cl.text = embed_content
		cl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		cl.add_theme_color_override("font_color", Color(0.8, 0.8, 0.85))
		cl.add_theme_font_size_override("font_size", 12)
		nvbox.add_child(cl)
	if not pubkey_request_pool.has(embed_pubkey):
		pubkey_request_pool.append(embed_pubkey)

func _rebuild_timeline_item(event: Dictionary) -> void:
	var pubkey: String = event["pubkey"]
	var content: String = event["content"]
	var is_repost: bool = event.get("is_repost", false)
	var repost_eid: String = event.get("repost_event_id", "")
	var repost_pk: String = event.get("repost_pubkey", "")
	var is_reply: bool = false
	if event.has("tags"):
		for t in event["tags"]:
			if t is Array and t.size() >= 2 and t[0] == "e":
				is_reply = true
				break

	var post_panel = PanelContainer.new()
	post_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	timeline.add_child(post_panel)

	var style_box = StyleBoxFlat.new()
	style_box.bg_color = Color(0.1, 0.11, 0.13)
	style_box.content_margin_left = 16
	style_box.content_margin_right = 16
	style_box.content_margin_top = 10
	style_box.content_margin_bottom = 10

	post_panel.add_theme_stylebox_override("panel", style_box)

	var main_hbox = HBoxContainer.new()
	main_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_hbox.add_theme_constant_override("separation", 12)
	post_panel.add_child(main_hbox)

	var avatar_rect = TextureRect.new()
	avatar_rect.custom_minimum_size = Vector2(44, 44)
	avatar_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	avatar_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	avatar_rect.clip_contents = true
	avatar_rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	main_hbox.add_child(avatar_rect)

	var right_vbox = VBoxContainer.new()
	right_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_hbox.add_child(right_vbox)

	if is_repost:
		var repost_header = Label.new()
		repost_header.text = "🔁 Repost"
		repost_header.add_theme_color_override("font_color", Color(0.4, 0.8, 0.6))
		repost_header.add_theme_font_size_override("font_size", 12)
		right_vbox.add_child(repost_header)

	if is_reply:
		var reply_badge = Label.new()
		reply_badge.text = "💬 Reply"
		reply_badge.add_theme_color_override("font_color", Color(0.6, 0.6, 0.8))
		reply_badge.add_theme_font_size_override("font_size", 12)
		right_vbox.add_child(reply_badge)

	var name_label = Label.new()
	name_label.add_theme_color_override("font_color", Color.GREEN_YELLOW)
	right_vbox.add_child(name_label)

	var entry_label = Label.new()
	entry_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right_vbox.add_child(entry_label)

	var hide_content: bool = is_repost and content.is_empty()
	if hide_content:
		entry_label.visible = false

	var has_npub_link: bool = false
	var npub_url: String = ""
	if content.begins_with("https://npub") or content.begins_with("nostr:"):
		has_npub_link = true
		npub_url = content.split("\n")[0].strip_edges()
	elif event.has("media_nostr_uris") and event["media_nostr_uris"].size() > 0:
		has_npub_link = true
		npub_url = event["media_nostr_uris"][0]

	var event_id: String = event.get("id", "")
	if NostrGD.IsLoggedIn and not event_id.is_empty():
		var action_hbox = HBoxContainer.new()
		action_hbox.add_theme_constant_override("separation", 4)
		right_vbox.add_child(action_hbox)

		var like_btn = Button.new()
		like_btn.text = "🩶"
		like_btn.custom_minimum_size = Vector2(28, 24)
		like_btn.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		like_btn.pressed.connect(_on_like_toggle.bind(event_id, pubkey, like_btn))
		action_hbox.add_child(like_btn)

		var stamp_btn = Button.new()
		stamp_btn.text = "📝"
		stamp_btn.custom_minimum_size = Vector2(28, 24)
		stamp_btn.pressed.connect(_open_stamp.bind(event_id, pubkey))
		action_hbox.add_child(stamp_btn)

		var has_wallet = profile_cache.has(pubkey) and profile_cache[pubkey] is Dictionary and (NostrUtils.has_lud(profile_cache[pubkey]))
		var zap_btn = Button.new()
		zap_btn.text = "⚡"
		zap_btn.custom_minimum_size = Vector2(28, 24)
		zap_btn.visible = has_wallet
		zap_btn.pressed.connect(_on_zap.bind(event_id, pubkey))
		action_hbox.add_child(zap_btn)

		if not _zap_buttons_by_pubkey.has(pubkey):
			_zap_buttons_by_pubkey[pubkey] = []
		_zap_buttons_by_pubkey[pubkey].append(zap_btn)

		var reply_btn = Button.new()
		reply_btn.text = "💬"
		reply_btn.custom_minimum_size = Vector2(28, 24)
		var reply_name = profile_cache.get(pubkey, {}).get("display_name", profile_cache.get(pubkey, {}).get("name", pubkey.left(8)))
		reply_btn.pressed.connect(_on_reply_button.bind(event_id, pubkey, reply_name, content))
		action_hbox.add_child(reply_btn)

		var repost_btn = Button.new()
		repost_btn.text = "🔁"
		repost_btn.custom_minimum_size = Vector2(28, 24)
		repost_btn.pressed.connect(_on_repost_button.bind(event_id))
		action_hbox.add_child(repost_btn)

	if profile_cache.has(pubkey) and profile_cache[pubkey] is Dictionary:
		var profile = profile_cache[pubkey]
		name_label.text = profile.get("display_name", profile.get("name", "Unknown"))
		entry_label.text = content

		var avatar_url = profile.get("picture", "")
		if avatar_url != "":
			_load_and_apply_avatar(avatar_url, avatar_rect)
	else:
		name_label.text = "[%s...]" % pubkey.left(8)
		entry_label.text = content

		if not pending_labels.has(pubkey):
			pending_labels[pubkey] = []
		pending_labels[pubkey].append({
			"name_label": name_label,
			"avatar_rect": avatar_rect,
			"content": content,
			"zap_btn": null
		})
		if not pubkey_request_pool.has(pubkey):
			pubkey_request_pool.append(pubkey)

	if event.has("media_hashtags") and event["media_hashtags"].size() > 0:
		var tag_hbox = HBoxContainer.new()
		tag_hbox.add_theme_constant_override("separation", 4)
		right_vbox.add_child(tag_hbox)
		for tag in event["media_hashtags"]:
			var tag_btn = Button.new()
			tag_btn.text = tag
			tag_btn.add_theme_color_override("font_color", Color(0.4, 0.6, 1.0))
			tag_btn.add_theme_font_size_override("font_size", 11)
			var tag_url = "https://nostr.band/?q=" + tag.trim_prefix("#").uri_encode()
			tag_btn.pressed.connect(func(): OS.shell_open(tag_url))
			tag_hbox.add_child(tag_btn)

	var note_id_from_content: String = ""
	if event.has("media_nostr_uris") and event["media_nostr_uris"].size() > 0:
		for uri in event["media_nostr_uris"]:
			var decoded = NostrUtils.decode_note1_id(uri)
			if decoded != "":
				note_id_from_content = decoded
				break

	var show_nested: bool = is_repost or has_npub_link or note_id_from_content != ""

	if show_nested:
		var nested_panel = PanelContainer.new()
		var nested_style = StyleBoxFlat.new()
		nested_style.bg_color = Color(0.05, 0.06, 0.08)
		nested_style.set_border_width_all(1)
		nested_style.border_color = Color(0.2, 0.22, 0.25)
		nested_style.corner_radius_top_left = 4
		nested_style.corner_radius_top_right = 4
		nested_style.corner_radius_bottom_right = 4
		nested_style.corner_radius_bottom_left = 4
		nested_style.content_margin_left = 8
		nested_style.content_margin_right = 8
		nested_style.content_margin_top = 6
		nested_style.content_margin_bottom = 6
		nested_panel.add_theme_stylebox_override("panel", nested_style)
		right_vbox.add_child(nested_panel)

		var nested_vbox = VBoxContainer.new()
		nested_vbox.add_theme_constant_override("separation", 4)
		nested_panel.add_child(nested_vbox)

		if is_repost and repost_eid != "":
			if event.has("repost_original_content") and event["repost_original_content"] != "":
				var orig_pk = event.get("repost_original_pubkey", "")
				var repost_name = orig_pk.left(12) + "..."
				if orig_pk != "" and profile_cache.has(orig_pk) and profile_cache[orig_pk] is Dictionary:
					repost_name = profile_cache[orig_pk].get("display_name", profile_cache[orig_pk].get("name", repost_name))
				var name_label2 = Label.new()
				name_label2.text = repost_name
				name_label2.add_theme_color_override("font_color", Color(0.3, 0.8, 0.3))
				name_label2.add_theme_font_size_override("font_size", 11)
				nested_vbox.add_child(name_label2)
				var content_label2 = Label.new()
				content_label2.text = event["repost_original_content"]
				content_label2.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				content_label2.add_theme_color_override("font_color", Color(0.8, 0.8, 0.85))
				content_label2.add_theme_font_size_override("font_size", 12)
				nested_vbox.add_child(content_label2)
				if event.has("repost_media_images"):
					var img_hbox2 = HBoxContainer.new()
					nested_vbox.add_child(img_hbox2)
					for img_url in event["repost_media_images"]:
						_load_and_display_image(img_url, img_hbox2)
				if event.has("repost_media_youtube_ids"):
					for yt_id in event["repost_media_youtube_ids"]:
						_render_youtube_embed(yt_id, nested_vbox)
			else:
				var loading_label = Label.new()
				loading_label.text = "読み込み中..."
				loading_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
				loading_label.add_theme_font_size_override("font_size", 11)
				nested_vbox.add_child(loading_label)
				var embed_sub_id = "embed_" + repost_eid.left(8)
				NostrGD.RequestEventById(repost_eid, embed_sub_id)
				_pending_embeds[repost_eid] = { "nested_vbox": nested_vbox, "parent_event_id": event.get("id", "") }
		elif has_npub_link and npub_url != "":
			var url_label = Label.new()
			url_label.text = "🔗 " + npub_url
			url_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			url_label.add_theme_color_override("font_color", Color(0.5, 0.7, 1))
			url_label.add_theme_font_size_override("font_size", 11)
			nested_vbox.add_child(url_label)
			var open_btn = Button.new()
			open_btn.text = "ブラウザで開く"
			open_btn.pressed.connect(func(): OS.shell_open(npub_url))
			nested_vbox.add_child(open_btn)
		elif note_id_from_content != "":
			var loading_label = Label.new()
			loading_label.text = "読み込み中..."
			loading_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
			loading_label.add_theme_font_size_override("font_size", 11)
			nested_vbox.add_child(loading_label)
			var embed_sub_id = "embed_" + note_id_from_content.left(8)
			NostrGD.RequestEventById(note_id_from_content, embed_sub_id)
			_pending_embeds[note_id_from_content] = { "nested_vbox": nested_vbox, "parent_event_id": event.get("id", "") }

	if event.has("media_images") and event["media_images"].size() > 0:
		var image_hbox = HBoxContainer.new()
		image_hbox.alignment = BoxContainer.ALIGNMENT_BEGIN
		right_vbox.add_child(image_hbox)

		for img_url in event["media_images"]:
			_load_and_display_image(img_url, image_hbox)

	if event.has("media_youtube_ids") and event["media_youtube_ids"].size() > 0:
		for yt_id in event["media_youtube_ids"]:
			_render_youtube_embed(yt_id, right_vbox)

	var all_links = []
	if event.has("media_nostr_uris"): all_links.append_array(event["media_nostr_uris"])
	if event.has("media_images"):
		for img_url in event["media_images"]:
			if not content.contains(img_url):
				all_links.append(img_url)
	if event.has("media_youtube"):
		for yt_url in event["media_youtube"]:
			if not content.contains(yt_url):
				all_links.append(yt_url)

	for link in all_links:
		var link_btn = LinkButton.new()
		link_btn.text = "🔗 " + link
		link_btn.underline = LinkButton.UNDERLINE_MODE_ON_HOVER
		link_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		link_btn.pressed.connect(func(): OS.shell_open(link))
		right_vbox.add_child(link_btn)

func _load_and_display_image(url: String, parent_node: Node) -> void:
	var cleaned_url = url.strip_edges()
	if cleaned_url.is_empty() or not cleaned_url.begins_with("http"):
		return

	if _image_texture_cache.has(cleaned_url):
		var cached_texture = _image_texture_cache[cleaned_url]
		if cached_texture == null:
			_image_texture_cache.erase(cleaned_url)
		else:
			var img_w = cached_texture.get_width()
			var img_h = cached_texture.get_height()
			var max_w = 420
			var max_h = 320
			var scale = min(min(max_w / max(img_w, 1), max_h / max(img_h, 1)), 1.0)
			var texture_rect = TextureRect.new()
			texture_rect.texture = cached_texture
			texture_rect.custom_minimum_size = Vector2(img_w * scale, img_h * scale)
			texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			parent_node.add_child(texture_rect)
		return

	var http_request = HTTPRequest.new()
	parent_node.add_child(http_request)

	var callback = func(result, response_code, _headers, body, node):
		if not is_instance_valid(node):
			return
		if result == HTTPRequest.RESULT_SUCCESS and response_code == 200:
			var image = Image.new()
			var error = OK
			var ext = cleaned_url.get_extension().to_lower().split("?")[0]
			if ext in ["jpg", "jpeg"]:
				error = image.load_jpg_from_buffer(body)
			elif ext == "png":
				error = image.load_png_from_buffer(body)
			elif ext == "webp":
				error = image.load_webp_from_buffer(body)
			elif ext.is_empty():
				error = image.load_jpg_from_buffer(body)
				if error != OK:
					error = image.load_png_from_buffer(body)
				if error != OK:
					error = image.load_webp_from_buffer(body)

			if error == OK and is_instance_valid(node):
				var texture = ImageTexture.create_from_image(image)
				_image_texture_cache[cleaned_url] = texture

				var texture_rect = TextureRect.new()
				texture_rect.texture = texture

				var img_w = image.get_width()
				var img_h = image.get_height()
				var max_w = 420
				var max_h = 320
				var scale = min(min(max_w / max(img_w, 1), max_h / max(img_h, 1)), 1.0)
				texture_rect.custom_minimum_size = Vector2(img_w * scale, img_h * scale)
				texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				node.add_child(texture_rect)

	if is_instance_valid(http_request):
		http_request.queue_free()

	http_request.request_completed.connect(callback.bind(parent_node))

	var err = http_request.request(cleaned_url)
	if err != OK:
		http_request.queue_free()

func _load_and_apply_avatar(url: String, target_rect: TextureRect) -> void:
	var cleaned_url = url.strip_edges()
	if cleaned_url.is_empty() or not cleaned_url.begins_with("http"):
		return

	if _avatar_texture_cache.has(cleaned_url):
		var cached = _avatar_texture_cache[cleaned_url]
		if cached != null:
			target_rect.texture = cached
		else:
			_avatar_texture_cache.erase(cleaned_url)
		return

	var http_request = HTTPRequest.new()
	add_child(http_request)

	var callback = func(result, response_code, _headers, body, rect):
		if not is_instance_valid(rect):
			return
		if result == HTTPRequest.RESULT_SUCCESS and response_code == 200:
			var image = Image.new()
			var error = OK
			var ext = cleaned_url.get_extension().to_lower().split("?")[0]

			if ext in ["jpg", "jpeg"]: error = image.load_jpg_from_buffer(body)
			elif ext == "png": error = image.load_png_from_buffer(body)
			elif ext == "webp": error = image.load_webp_from_buffer(body)
			elif ext.is_empty():
				error = image.load_jpg_from_buffer(body)
				if error != OK:
					error = image.load_png_from_buffer(body)
				if error != OK:
					error = image.load_webp_from_buffer(body)

			if error == OK and is_instance_valid(rect):
				var texture = ImageTexture.create_from_image(image)
				if texture != null:
					_avatar_texture_cache[cleaned_url] = texture
					rect.texture = texture

		if is_instance_valid(http_request):
			http_request.queue_free()

	http_request.request_completed.connect(callback.bind(target_rect))

	var err = http_request.request(cleaned_url)
	if err != OK:
		http_request.queue_free()

func _load_and_apply_banner(url: String, target_rect: TextureRect) -> void:
	var cleaned_url = url.strip_edges()
	if cleaned_url.is_empty() or not cleaned_url.begins_with("http"):
		return
	if _avatar_texture_cache.has(cleaned_url):
		var cached = _avatar_texture_cache[cleaned_url]
		if cached != null:
			target_rect.texture = cached
		else:
			_avatar_texture_cache.erase(cleaned_url)
		return
	var http_request = HTTPRequest.new()
	add_child(http_request)
	var callback = func(result, response_code, _headers, body, rect):
		if not is_instance_valid(rect):
			return
		if result == HTTPRequest.RESULT_SUCCESS and response_code == 200:
			var image = Image.new()
			var error = OK
			var ext = cleaned_url.get_extension().to_lower().split("?")[0]
			if ext in ["jpg", "jpeg"]: error = image.load_jpg_from_buffer(body)
			elif ext == "png": error = image.load_png_from_buffer(body)
			elif ext == "webp": error = image.load_webp_from_buffer(body)
			elif ext.is_empty():
				error = image.load_jpg_from_buffer(body)
				if error != OK:
					error = image.load_png_from_buffer(body)
				if error != OK:
					error = image.load_webp_from_buffer(body)
			if error == OK and is_instance_valid(rect):
				var texture = ImageTexture.create_from_image(image)
				if texture != null:
					_avatar_texture_cache[cleaned_url] = texture
					rect.texture = texture
		if is_instance_valid(http_request):
			http_request.queue_free()
	http_request.request_completed.connect(callback.bind(target_rect))
	var err = http_request.request(cleaned_url)
	if err != OK:
		http_request.queue_free()

func _on_pool_timer_timeout() -> void:
	if pubkey_request_pool.is_empty():
		return

	NostrGD.RequestProfiles("profile_resolver", pubkey_request_pool)

	pubkey_request_pool.clear()

func _parse_profile_event(event: Dictionary) -> void:
	var pubkey: String = event["pubkey"]
	var raw_content: String = event["content"]

	var json = JSON.new()
	if json.parse(raw_content) == OK:
		var profile_data = json.get_data()

		profile_cache[pubkey] = profile_data

		var user_name = profile_data.get("display_name", profile_data.get("name", pubkey.left(8)))
		var avatar_url = profile_data.get("picture", "")

		if pending_labels.has(pubkey):
			for item in pending_labels[pubkey]:
				if item.has("name_label") and is_instance_valid(item["name_label"]):
					item["name_label"].text = user_name

				if avatar_url != "" and item.has("avatar_rect") and is_instance_valid(item["avatar_rect"]):
					_load_and_apply_avatar(avatar_url, item["avatar_rect"])
			pending_labels.erase(pubkey)

		if NostrGD.IsLoggedIn and pubkey == NostrGD.GetPublicKeyHex() and _current_section == Section.PROFILE:
			_refresh_profile()

		if _current_section == Section.NOTIFICATIONS:
			for nev in _notifications_events:
				if nev.get("pubkey", "") == pubkey:
					_refresh_notifications()
					break

		if _zap_buttons_by_pubkey.has(pubkey):
			var has_wallet = NostrUtils.has_lud(profile_data)
			for btn in _zap_buttons_by_pubkey[pubkey]:
				if is_instance_valid(btn):
					btn.visible = has_wallet

func _render_youtube_embed(video_id: String, parent: Node) -> void:
	var yt_url = "https://www.youtube.com/watch?v=%s" % video_id
	var thumb_url = "https://img.youtube.com/vi/%s/hqdefault.jpg" % video_id

	var yt_hbox = HBoxContainer.new()
	yt_hbox.alignment = BoxContainer.ALIGNMENT_BEGIN
	parent.add_child(yt_hbox)

	var play_btn = Button.new()
	play_btn.text = "▶ " + video_id
	play_btn.custom_minimum_size = Vector2(320, 40)
	play_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	play_btn.pressed.connect(func(): OS.shell_open(yt_url))
	yt_hbox.add_child(play_btn)

	var thumb_rect = TextureRect.new()
	thumb_rect.custom_minimum_size = Vector2(320, 180)
	thumb_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	thumb_rect.clip_contents = true
	thumb_rect.mouse_filter = Control.MOUSE_FILTER_PASS
	yt_hbox.add_child(thumb_rect)

	thumb_rect.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			OS.shell_open(yt_url)
	)

	_load_youtube_thumbnail(thumb_url, thumb_rect)


func _load_youtube_thumbnail(url: String, target_rect: TextureRect) -> void:
	if not is_instance_valid(target_rect):
		return
	var http_request = HTTPRequest.new()
	add_child(http_request)
	var req_id = http_request.request(url)
	if req_id != OK:
		http_request.queue_free()
		return
	http_request.request_completed.connect(func(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
		if not is_instance_valid(target_rect) or not is_instance_valid(http_request):
			return
		if result == HTTPRequest.RESULT_SUCCESS and response_code == 200:
			var image = Image.new()
			if image.load_jpg_from_buffer(body) == OK:
				target_rect.texture = ImageTexture.create_from_image(image)
		http_request.queue_free()
	)
