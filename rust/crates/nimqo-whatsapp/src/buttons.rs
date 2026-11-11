//! Messages with buttons: buttons, templates, lists and interactive
//! (native flow) messages, as businesses and bots send them. Kept whole as
//! a card; drawn as text with its buttons; a reply button or list row
//! answers with the response message the sender expects.

use serde_json::Value;
use wa::__buffa::oneof::hydrated_template_button::HydratedButton;
use wa::__buffa::oneof::message::buttons_message::Header as ButtonsHeader;
use wa::__buffa::oneof::message::buttons_response_message::Response;
use wa::__buffa::oneof::message::interactive_message::InteractiveMessage as Flow;
use wa::__buffa::oneof::message::interactive_message::header::Media;
use wa::__buffa::oneof::message::interactive_response_message::InteractiveResponseMessage as FlowResponse;
use wa::__buffa::oneof::message::template_message::Format;
use wa::__buffa::oneof::message::template_message::hydrated_four_row_template::Title;
use whatsapp_rust::buffa::{Message as _, MessageField};
use whatsapp_rust::prelude::wa;

/// At most this many buttons, sections and rows are kept.
const MAX_ITEMS: usize = 32;

/// What a button does when pressed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    /// Answers the sender with its id.
    Reply,
    /// Opens a web link.
    Url(String),
    /// Copies a code.
    Copy(String),
    /// Calls a number.
    Call(String),
    /// Something only the phone does (payments, forms, locations).
    Unsupported,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Button {
    pub id: String,
    pub label: String,
    pub action: Action,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row {
    pub id: String,
    pub title: String,
    pub description: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Section {
    pub title: Option<String>,
    pub rows: Vec<Row>,
}

/// A list behind one button.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct List {
    pub button: String,
    pub sections: Vec<Section>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Buttons {
    pub header: Option<String>,
    /// The header picture's small preview, when it has one.
    pub thumbnail: Option<Vec<u8>>,
    pub body: Option<String>,
    pub footer: Option<String>,
    pub buttons: Vec<Button>,
    pub list: Option<List>,
}

fn some(s: Option<&str>) -> Option<String> {
    s.map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}

fn template(
    t: &wa::message::TemplateMessage,
) -> Option<&wa::message::template_message::HydratedFourRowTemplate> {
    t.hydrated_template.as_option().or(match &t.format {
        Some(Format::HydratedFourRowTemplate(h)) => Some(h),
        _ => None,
    })
}

fn template_flow(t: &wa::message::TemplateMessage) -> Option<&wa::message::InteractiveMessage> {
    match &t.format {
        Some(Format::InteractiveMessageTemplate(m)) => Some(m),
        _ => None,
    }
}

/// Read from a message, or `None` when it has no buttons part.
#[must_use]
pub fn parse(b: &wa::Message) -> Option<Buttons> {
    if let Some(m) = b.buttons_message.as_option() {
        return Some(buttons_message(m));
    }
    if let Some(t) = b.template_message.as_option() {
        if let Some(m) = template_flow(t) {
            return Some(interactive(m));
        }
        return Some(hydrated(template(t)?));
    }
    if let Some(l) = b.list_message.as_option() {
        return Some(list(l));
    }
    b.interactive_message.as_option().map(interactive)
}

fn buttons_message(m: &wa::message::ButtonsMessage) -> Buttons {
    let mut out = Buttons {
        body: some(m.content_text.as_deref()),
        footer: some(m.footer_text.as_deref()),
        ..Buttons::default()
    };
    match &m.header {
        Some(ButtonsHeader::Text(t)) => out.header = some(Some(t.as_str())),
        Some(ButtonsHeader::ImageMessage(i)) => out.thumbnail.clone_from(&i.jpeg_thumbnail),
        Some(ButtonsHeader::VideoMessage(v)) => out.thumbnail.clone_from(&v.jpeg_thumbnail),
        Some(ButtonsHeader::DocumentMessage(d)) => {
            out.header = some(d.file_name.as_deref().or(d.title.as_deref()));
            out.thumbnail.clone_from(&d.jpeg_thumbnail);
        }
        Some(ButtonsHeader::LocationMessage(l)) => {
            out.header = some(l.name.as_deref());
            out.thumbnail.clone_from(&l.jpeg_thumbnail);
        }
        _ => {}
    }
    for button in m.buttons.iter().take(MAX_ITEMS) {
        if let Some(flow) = button.native_flow_info.as_option() {
            flow_button(
                &mut out,
                flow.name.as_deref().unwrap_or_default(),
                flow.params_json.as_deref().unwrap_or_default(),
            );
        } else if let Some(label) = some(
            button
                .button_text
                .as_option()
                .and_then(|t| t.display_text.as_deref()),
        ) {
            out.buttons.push(Button {
                id: button.button_id.clone().unwrap_or_default(),
                label,
                action: Action::Reply,
            });
        }
    }
    out
}

fn hydrated(h: &wa::message::template_message::HydratedFourRowTemplate) -> Buttons {
    let mut out = Buttons {
        body: some(h.hydrated_content_text.as_deref()),
        footer: some(h.hydrated_footer_text.as_deref()),
        ..Buttons::default()
    };
    match &h.title {
        Some(Title::HydratedTitleText(t)) => out.header = some(Some(t.as_str())),
        Some(Title::ImageMessage(i)) => out.thumbnail.clone_from(&i.jpeg_thumbnail),
        Some(Title::VideoMessage(v)) => out.thumbnail.clone_from(&v.jpeg_thumbnail),
        Some(Title::DocumentMessage(d)) => {
            out.header = some(d.file_name.as_deref().or(d.title.as_deref()));
            out.thumbnail.clone_from(&d.jpeg_thumbnail);
        }
        _ => {}
    }
    for button in h.hydrated_buttons.iter().take(MAX_ITEMS) {
        let (id, label, action) = match &button.hydrated_button {
            Some(HydratedButton::QuickReplyButton(q)) => (
                q.id.clone().unwrap_or_default(),
                q.display_text.as_deref(),
                Action::Reply,
            ),
            Some(HydratedButton::UrlButton(u)) => (
                String::new(),
                u.display_text.as_deref(),
                u.url.clone().map_or(Action::Unsupported, Action::Url),
            ),
            Some(HydratedButton::CallButton(c)) => (
                String::new(),
                c.display_text.as_deref(),
                c.phone_number
                    .clone()
                    .map_or(Action::Unsupported, Action::Call),
            ),
            _ => continue,
        };
        if let Some(label) = some(label) {
            out.buttons.push(Button { id, label, action });
        }
    }
    out
}

fn list(l: &wa::message::ListMessage) -> Buttons {
    let sections = l
        .sections
        .iter()
        .take(MAX_ITEMS)
        .map(|s| Section {
            title: some(s.title.as_deref()),
            rows: s
                .rows
                .iter()
                .take(MAX_ITEMS)
                .filter_map(|r| {
                    Some(Row {
                        id: r.row_id.clone().unwrap_or_default(),
                        title: some(r.title.as_deref())?,
                        description: some(r.description.as_deref()),
                    })
                })
                .collect(),
        })
        .collect();
    Buttons {
        header: some(l.title.as_deref()),
        body: some(l.description.as_deref()),
        footer: some(l.footer_text.as_deref()),
        list: Some(List {
            button: some(l.button_text.as_deref()).unwrap_or_else(|| "Choose".to_owned()),
            sections,
        }),
        ..Buttons::default()
    }
}

fn interactive(m: &wa::message::InteractiveMessage) -> Buttons {
    let mut out = Buttons {
        body: some(m.body.as_option().and_then(|b| b.text.as_deref())),
        footer: some(m.footer.as_option().and_then(|f| f.text.as_deref())),
        ..Buttons::default()
    };
    if let Some(h) = m.header.as_option() {
        out.header = some(h.title.as_deref());
        out.thumbnail = match &h.media {
            Some(Media::JpegThumbnail(t)) => Some(t.clone()),
            Some(Media::ImageMessage(i)) => i.jpeg_thumbnail.clone(),
            Some(Media::VideoMessage(v)) => v.jpeg_thumbnail.clone(),
            Some(Media::DocumentMessage(d)) => d.jpeg_thumbnail.clone(),
            _ => None,
        };
    }
    if let Some(Flow::NativeFlowMessage(flow)) = &m.interactive_message {
        for button in flow.buttons.iter().take(MAX_ITEMS) {
            flow_button(
                &mut out,
                button.name.as_deref().unwrap_or_default(),
                button.button_params_json.as_deref().unwrap_or_default(),
            );
        }
    }
    out
}

/// A native flow button, from its name and JSON parameters.
fn flow_button(out: &mut Buttons, name: &str, params: &str) {
    let params: Value = serde_json::from_str(params).unwrap_or(Value::Null);
    let text = |key: &str| some(params.get(key).and_then(Value::as_str));
    if name == "single_select" {
        let sections = params
            .get("sections")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .take(MAX_ITEMS)
            .map(|s| Section {
                title: some(s.get("title").and_then(Value::as_str)),
                rows: s
                    .get("rows")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .take(MAX_ITEMS)
                    .filter_map(|r| {
                        let get = |key: &str| some(r.get(key).and_then(Value::as_str));
                        Some(Row {
                            id: get("id")?,
                            title: get("title").or_else(|| get("header"))?,
                            description: get("description"),
                        })
                    })
                    .collect(),
            })
            .collect();
        out.list = Some(List {
            button: text("title").unwrap_or_else(|| "Choose".to_owned()),
            sections,
        });
        return;
    }
    let Some(label) = text("display_text").or_else(|| text("title")) else {
        return;
    };
    let action = match name {
        "quick_reply" => Action::Reply,
        "cta_url" => text("url").map_or(Action::Unsupported, Action::Url),
        "cta_copy" => text("copy_code").map_or(Action::Unsupported, Action::Copy),
        "cta_call" => text("phone_number").map_or(Action::Unsupported, Action::Call),
        _ => Action::Unsupported,
    };
    out.buttons.push(Button {
        id: text("id").unwrap_or_default(),
        label,
        action,
    });
}

/// The kind and its line in the chat list and search.
pub(crate) fn classify(b: &wa::Message) -> Option<(&'static str, Option<String>)> {
    let parsed = parse(b)?;
    if parsed.buttons.is_empty() && parsed.list.is_none() {
        return None;
    }
    let line = parsed
        .body
        .clone()
        .or_else(|| parsed.header.clone())
        .or_else(|| parsed.buttons.first().map(|b| b.label.clone()))
        .or_else(|| parsed.list.as_ref().map(|l| l.button.clone()));
    Some(("buttons", line))
}

/// What is kept: the buttons part alone, without its context.
pub(crate) fn kept(b: &wa::Message) -> Option<Vec<u8>> {
    classify(b)?;
    let mut kept = wa::Message::default();
    if let Some(m) = b.buttons_message.as_option() {
        let mut m = m.clone();
        m.context_info = MessageField::none();
        kept.buttons_message = MessageField::some(m);
    } else if let Some(m) = b.template_message.as_option() {
        let mut m = m.clone();
        m.context_info = MessageField::none();
        kept.template_message = MessageField::some(m);
    } else if let Some(m) = b.list_message.as_option() {
        let mut m = m.clone();
        m.context_info = MessageField::none();
        kept.list_message = MessageField::some(m);
    } else {
        let mut m = b.interactive_message.as_option()?.clone();
        m.context_info = MessageField::none();
        kept.interactive_message = MessageField::some(m);
    }
    Some(kept.encode_to_vec())
}

/// The answer to pressing reply button or list row `id` of `card` (as
/// kept), quoting it with `context`; and the text it shows as.
#[must_use]
pub fn reply(
    card: &wa::Message,
    id: &str,
    context: wa::ContextInfo,
) -> Option<(wa::Message, String)> {
    let parsed = parse(card)?;
    let button = parsed
        .buttons
        .iter()
        .find(|b| b.action == Action::Reply && b.id == id && !id.is_empty());
    let row = parsed
        .list
        .iter()
        .flat_map(|l| &l.sections)
        .flat_map(|s| &s.rows)
        .find(|r| r.id == id && !id.is_empty());
    let label = button
        .map(|b| b.label.clone())
        .or_else(|| row.map(|r| r.title.clone()))?;
    let context = MessageField::some(context);
    let mut out = wa::Message::default();
    let flow = card.interactive_message.as_option().is_some()
        || card
            .template_message
            .as_option()
            .is_some_and(|t| template_flow(t).is_some())
        || card.buttons_message.as_option().is_some_and(|m| {
            m.buttons
                .iter()
                .any(|b| b.native_flow_info.as_option().is_some())
        });
    if flow {
        let mut r = wa::message::InteractiveResponseMessage::default();
        let mut body = wa::message::interactive_response_message::Body::default();
        body.text = Some(label.clone());
        r.body = MessageField::some(body);
        let mut native =
            wa::message::interactive_response_message::NativeFlowResponseMessage::default();
        native.name = Some(
            if row.is_some() {
                "single_select"
            } else {
                "quick_reply"
            }
            .to_owned(),
        );
        native.params_json = Some(serde_json::json!({ "id": id }).to_string());
        native.version = Some(3);
        r.interactive_response_message =
            Some(FlowResponse::NativeFlowResponseMessage(Box::new(native)));
        r.context_info = context;
        out.interactive_response_message = MessageField::some(r);
    } else if let Some(row) = row {
        let mut r = wa::message::ListResponseMessage::default();
        r.title = Some(row.title.clone());
        r.description.clone_from(&row.description);
        r.list_type = Some(wa::message::list_response_message::ListType::SINGLE_SELECT);
        let mut single = wa::message::list_response_message::SingleSelectReply::default();
        single.selected_row_id = Some(row.id.clone());
        r.single_select_reply = MessageField::some(single);
        r.context_info = context;
        out.list_response_message = MessageField::some(r);
    } else if let Some(t) = card.template_message.as_option().and_then(template) {
        let index = t
            .hydrated_buttons
            .iter()
            .find_map(|b| match &b.hydrated_button {
                Some(HydratedButton::QuickReplyButton(q)) if q.id.as_deref() == Some(id) => b.index,
                _ => None,
            });
        let mut r = wa::message::TemplateButtonReplyMessage::default();
        r.selected_id = Some(id.to_owned());
        r.selected_display_text = Some(label.clone());
        r.selected_index = index;
        r.context_info = context;
        out.template_button_reply_message = MessageField::some(r);
    } else {
        let mut r = wa::message::ButtonsResponseMessage::default();
        r.selected_button_id = Some(id.to_owned());
        r.response = Some(Response::SelectedDisplayText(label.clone()));
        r.r#type = Some(wa::message::buttons_response_message::Type::DISPLAY_TEXT);
        r.context_info = context;
        out.buttons_response_message = MessageField::some(r);
    }
    Some((out, label))
}

/// The text of an answer to buttons, sent from here or another device.
pub(crate) fn answer_text(b: &wa::Message) -> Option<String> {
    if let Some(r) = b.buttons_response_message.as_option() {
        return match &r.response {
            Some(Response::SelectedDisplayText(t)) => some(Some(t.as_str())),
            _ => None,
        };
    }
    if let Some(r) = b.template_button_reply_message.as_option() {
        return some(r.selected_display_text.as_deref());
    }
    if let Some(r) = b.list_response_message.as_option() {
        return some(r.title.as_deref());
    }
    let r = b.interactive_response_message.as_option()?;
    some(r.body.as_option().and_then(|b| b.text.as_deref()))
}

#[must_use]
pub fn decode(kept: &[u8]) -> Option<wa::Message> {
    wa::Message::decode_from_slice(kept).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn flow(buttons: &[(&str, &str)]) -> wa::Message {
        let mut native = wa::message::interactive_message::NativeFlowMessage::default();
        for (name, params) in buttons {
            let mut b =
                wa::message::interactive_message::native_flow_message::NativeFlowButton::default();
            b.name = Some((*name).to_owned());
            b.button_params_json = Some((*params).to_owned());
            native.buttons.push(b);
        }
        let mut m = wa::message::InteractiveMessage::default();
        let mut body = wa::message::interactive_message::Body::default();
        body.text = Some("Your code".into());
        m.body = MessageField::some(body);
        m.interactive_message = Some(Flow::NativeFlowMessage(Box::new(native)));
        let mut out = wa::Message::default();
        out.interactive_message = MessageField::some(m);
        out
    }

    #[test]
    fn native_flow_buttons_are_read_and_answered() {
        let m = flow(&[
            (
                "cta_copy",
                r#"{"display_text":"Copy","copy_code":"123456"}"#,
            ),
            (
                "cta_url",
                r#"{"display_text":"Open","url":"https://example.com"}"#,
            ),
            ("quick_reply", r#"{"display_text":"Yes","id":"y"}"#),
            ("payment_info", r#"{"display_text":"Pay"}"#),
        ]);
        assert_eq!(classify(&m), Some(("buttons", Some("Your code".into()))));
        let kept = decode(&kept(&m).unwrap()).unwrap();
        let parsed = parse(&kept).unwrap();
        let actions: Vec<_> = parsed.buttons.iter().map(|b| b.action.clone()).collect();
        assert_eq!(
            actions,
            [
                Action::Copy("123456".into()),
                Action::Url("https://example.com".into()),
                Action::Reply,
                Action::Unsupported
            ]
        );
        let (answer, label) = reply(&kept, "y", wa::ContextInfo::default()).unwrap();
        assert_eq!(label, "Yes");
        assert_eq!(answer_text(&answer).as_deref(), Some("Yes"));
        // Only reply buttons answer; an unknown id does not.
        assert!(reply(&kept, "", wa::ContextInfo::default()).is_none());
        assert!(reply(&kept, "nope", wa::ContextInfo::default()).is_none());
    }

    #[test]
    fn a_list_answers_with_its_row() {
        let mut l = wa::message::ListMessage::default();
        l.description = Some("Pick one".into());
        l.button_text = Some("Menu".into());
        let mut s = wa::message::list_message::Section::default();
        let mut r = wa::message::list_message::Row::default();
        r.row_id = Some("r1".into());
        r.title = Some("Coffee".into());
        s.rows.push(r);
        l.sections.push(s);
        let mut m = wa::Message::default();
        m.list_message = MessageField::some(l);
        let parsed = parse(&m).unwrap();
        assert_eq!(parsed.list.as_ref().unwrap().button, "Menu");
        let (answer, label) = reply(&m, "r1", wa::ContextInfo::default()).unwrap();
        assert_eq!(label, "Coffee");
        let r = answer.list_response_message.as_option().unwrap();
        assert_eq!(
            r.single_select_reply
                .as_option()
                .unwrap()
                .selected_row_id
                .as_deref(),
            Some("r1")
        );
    }
}
