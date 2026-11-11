//! Messages with buttons as the timeline draws them, and pressing one.

use std::sync::Arc;

use nimqo_whatsapp::buttons::{self as b, Action};

use crate::{Core, CoreError};

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ButtonAction {
    /// Answers the sender (`press_button`).
    Reply,
    Url {
        url: String,
    },
    Copy {
        code: String,
    },
    Call {
        phone: String,
    },
    /// Only the phone does it.
    Unsupported,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MessageButton {
    pub id: String,
    pub label: String,
    pub action: ButtonAction,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ButtonRow {
    pub id: String,
    pub title: String,
    pub description: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ButtonSection {
    pub title: Option<String>,
    pub rows: Vec<ButtonRow>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ButtonsCard {
    pub header: Option<String>,
    /// The header picture's small preview (JPEG).
    pub thumbnail: Option<Vec<u8>>,
    pub body: Option<String>,
    pub footer: Option<String>,
    pub buttons: Vec<MessageButton>,
    /// The button that opens the list, and its sections; nil without one.
    pub list_button: Option<String>,
    pub sections: Vec<ButtonSection>,
}

pub(crate) fn card(m: &whatsapp_rust::prelude::wa::Message) -> Option<ButtonsCard> {
    let parsed = b::parse(m)?;
    Some(ButtonsCard {
        header: parsed.header,
        thumbnail: parsed.thumbnail,
        body: parsed.body,
        footer: parsed.footer,
        buttons: parsed
            .buttons
            .into_iter()
            .map(|button| MessageButton {
                id: button.id,
                label: button.label,
                action: match button.action {
                    Action::Reply => ButtonAction::Reply,
                    Action::Url(url) => ButtonAction::Url { url },
                    Action::Copy(code) => ButtonAction::Copy { code },
                    Action::Call(phone) => ButtonAction::Call { phone },
                    Action::Unsupported => ButtonAction::Unsupported,
                },
            })
            .collect(),
        list_button: parsed.list.as_ref().map(|l| l.button.clone()),
        sections: parsed
            .list
            .map(|l| l.sections)
            .unwrap_or_default()
            .into_iter()
            .map(|s| ButtonSection {
                title: s.title,
                rows: s
                    .rows
                    .into_iter()
                    .map(|r| ButtonRow {
                        id: r.id,
                        title: r.title,
                        description: r.description,
                    })
                    .collect(),
            })
            .collect(),
    })
}

#[uniffi::export]
impl Core {
    /// Answers message `seq` (one with buttons) as its reply button or list
    /// row `id` would on the phone. Only when the user pressed it.
    ///
    /// # Errors
    /// `SendRefused` when sending is not allowed here or `id` is not one of
    /// its reply buttons or rows; `Storage` when it cannot be queued.
    pub fn press_button(&self, chat_id: &str, seq: i64, id: &str) -> Result<(), CoreError> {
        self.sender.send_choice(chat_id, seq, id)?;
        let sender = Arc::clone(&self.sender);
        self.runtime.spawn(async move { sender.flush(false).await });
        Ok(())
    }
}
