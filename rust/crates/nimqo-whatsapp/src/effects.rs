//! Messages that change other messages: edits, deletes for everyone, and
//! reactions. They are applied in the same transaction as the batch they
//! arrive in, so the durability guarantee covers them too.
//!
//! An edit or delete only matches a message from the same sender in the
//! same chat, so nobody can rewrite someone else's message by naming its id.

use diesel::sql_types::Text;
use diesel::{OptionalExtension, QueryResult, RunQueryDsl, SqliteConnection};
use whatsapp_rust::prelude::{MessageExt, wa};
use whatsapp_rust::types::durability_hook::InboundMessage;

use crate::inbox::{chat_key, classify, sender_key};

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Effect {
    Edit {
        chat: String,
        sender: String,
        target: String,
        kind: &'static str,
        body: Option<String>,
    },
    Revoke {
        chat: String,
        sender: String,
        target: String,
    },
    /// The chat's disappearing-message timer; 0 turns it off.
    Timer { chat: String, seconds: u32 },
    /// `emoji` None removes the reaction.
    React {
        chat: String,
        reactor: String,
        target: String,
        emoji: Option<String>,
    },
}

impl Effect {
    pub(crate) fn from_inbound(m: &InboundMessage) -> Option<Self> {
        let src = &m.info.source;
        Self::parse(&m.message, chat_key(src), sender_key(src))
    }

    fn parse(message: &wa::Message, chat: String, sender: String) -> Option<Self> {
        use wa::message::protocol_message::Type;
        let base = message.get_base_message();
        if let Some(r) = base.reaction_message.as_option() {
            let target = r.key.as_option()?.id.clone()?;
            let emoji = r.text.clone().filter(|t| !t.is_empty());
            return Some(Self::React {
                chat,
                reactor: sender,
                target,
                emoji,
            });
        }
        let p = base.protocol_message.as_option()?;
        // Timer changes carry no key: they change the chat, not a message.
        if p.r#type? == Type::EPHEMERAL_SETTING {
            return Some(Self::Timer {
                chat,
                seconds: p.ephemeral_expiration.unwrap_or(0),
            });
        }
        let target = p.key.as_option()?.id.clone()?;
        match p.r#type? {
            Type::REVOKE => Some(Self::Revoke {
                chat,
                sender,
                target,
            }),
            Type::MESSAGE_EDIT => {
                let (kind, body) = classify(p.edited_message.as_option()?)?;
                Some(Self::Edit {
                    chat,
                    sender,
                    target,
                    kind,
                    body,
                })
            }
            _ => None,
        }
    }

    pub(crate) fn chat_mut(&mut self) -> &mut String {
        match self {
            Self::Edit { chat, .. }
            | Self::Revoke { chat, .. }
            | Self::React { chat, .. }
            | Self::Timer { chat, .. } => chat,
        }
    }

    pub(crate) fn chat(&self) -> &str {
        match self {
            Self::Edit { chat, .. }
            | Self::Revoke { chat, .. }
            | Self::React { chat, .. }
            | Self::Timer { chat, .. } => chat,
        }
    }

    // ponytail: an edit or delete that arrives before its message is dropped;
    // keep pending effects if that shows up in practice.
    pub(crate) fn apply(&self, c: &mut SqliteConnection) -> QueryResult<()> {
        match self {
            Self::Edit {
                chat,
                sender,
                target,
                kind,
                body,
            } => diesel::sql_query(
                "UPDATE messages SET kind = ?, body = ?, edited = 1
                 WHERE chat = ? AND sender = ? AND id = ? AND kind <> 'deleted'",
            )
            .bind::<Text, _>(*kind)
            .bind::<diesel::sql_types::Nullable<Text>, _>(body)
            .bind::<Text, _>(chat)
            .bind::<Text, _>(sender)
            .bind::<Text, _>(target)
            .execute(c),
            Self::Revoke {
                chat,
                sender,
                target,
            } => diesel::sql_query(
                "UPDATE messages SET kind = 'deleted', body = NULL, media = NULL
                 WHERE chat = ? AND sender = ? AND id = ?",
            )
            .bind::<Text, _>(chat)
            .bind::<Text, _>(sender)
            .bind::<Text, _>(target)
            .execute(c),
            Self::Timer { chat, seconds } => {
                diesel::sql_query("INSERT OR REPLACE INTO chat_timers (chat, seconds) VALUES (?, ?)")
                    .bind::<Text, _>(chat)
                    .bind::<diesel::sql_types::BigInt, _>(i64::from(*seconds))
                    .execute(c)
            }
            Self::React {
                chat,
                reactor,
                target,
                emoji: Some(emoji),
            } => diesel::sql_query(
                "INSERT OR REPLACE INTO reactions (chat, target, reactor, emoji) VALUES (?, ?, ?, ?)",
            )
            .bind::<Text, _>(chat)
            .bind::<Text, _>(target)
            .bind::<Text, _>(reactor)
            .bind::<Text, _>(emoji)
            .execute(c),
            Self::React {
                chat,
                reactor,
                target,
                emoji: None,
            } => diesel::sql_query(
                "DELETE FROM reactions WHERE chat = ? AND target = ? AND reactor = ?",
            )
            .bind::<Text, _>(chat)
            .bind::<Text, _>(target)
            .bind::<Text, _>(reactor)
            .execute(c),
        }
        .map(|_| ())
    }
}

impl crate::inbox::Inbox {
    /// The id of message `seq` in `chat` and whether it is own, to react to.
    ///
    /// # Errors
    /// The store cannot be read.
    pub fn message_key(&self, chat: &str, seq: i64) -> anyhow::Result<Option<(String, bool)>> {
        #[derive(diesel::QueryableByName)]
        struct Key {
            #[diesel(sql_type = Text)]
            id: String,
            #[diesel(sql_type = diesel::sql_types::Bool)]
            from_me: bool,
        }
        let mut conn = self.lock()?;
        let key: Option<Key> = diesel::sql_query(
            "SELECT id, from_me FROM messages WHERE rowid = ? AND chat = ? AND kind <> 'deleted'",
        )
        .bind::<diesel::sql_types::BigInt, _>(seq)
        .bind::<Text, _>(chat)
        .get_result(&mut *conn)
        .optional()?;
        Ok(key.map(|k| (k.id, k.from_me)))
    }

    /// Stores this account's reaction to `target`; None removes it.
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn set_own_reaction(
        &self,
        chat: &str,
        target: &str,
        emoji: Option<&str>,
    ) -> anyhow::Result<()> {
        let react = Effect::React {
            chat: chat.to_owned(),
            reactor: crate::inbox::ME.to_owned(),
            target: target.to_owned(),
            emoji: emoji.map(str::to_owned),
        };
        self.commit(Vec::new(), &[react])
    }
}

#[cfg(test)]
mod tests {
    use whatsapp_rust::buffa::MessageField;
    use whatsapp_rust::prelude::MessageBuilderExt;

    use super::*;
    use crate::inbox::{Fault, Inbox};
    use crate::vault::Key;

    #[test]
    fn own_reactions_are_kept_apart_from_others() {
        let path = std::env::temp_dir().join(format!("nimqo-react-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let inbox = Inbox::open(&path, &Key::new([5; 32]), Fault::None).unwrap();
        let chat = "62811@s.whatsapp.net";
        inbox.insert_kind_for_test(chat, "m1", "text", Vec::new());
        let row = || inbox.messages(chat, 10).unwrap().remove(0);
        let seq = row().seq;
        assert_eq!(
            inbox.message_key(chat, seq).unwrap(),
            Some(("m1".into(), false))
        );
        assert_eq!(inbox.message_key("x@s.whatsapp.net", seq).unwrap(), None);
        inbox.apply_for_test(&[Effect::React {
            chat: chat.into(),
            reactor: chat.into(),
            target: "m1".into(),
            emoji: Some("😂".into()),
        }]);
        inbox.set_own_reaction(chat, "m1", Some("👍")).unwrap();
        assert_eq!(row().my_reaction.as_deref(), Some("👍"));
        assert_eq!(row().reactions.map(|r| r.chars().count()), Some(2));
        inbox.set_own_reaction(chat, "m1", None).unwrap();
        assert_eq!(
            (row().my_reaction, row().reactions.as_deref()),
            (None, Some("😂"))
        );
        drop(inbox);
        std::fs::remove_file(&path).unwrap();
    }

    fn key(id: &str) -> MessageField<wa::MessageKey> {
        let mut k = wa::MessageKey::default();
        k.id = Some(id.into());
        MessageField::some(k)
    }

    fn edit(id: &str, text: &str) -> wa::Message {
        let mut p = wa::message::ProtocolMessage::default();
        p.key = key(id);
        p.r#type = Some(wa::message::protocol_message::Type::MESSAGE_EDIT);
        p.edited_message = MessageField::some(wa::Message::text(text));
        let mut m = wa::Message::default();
        m.protocol_message = MessageField::some(p);
        m
    }

    fn revoke(id: &str) -> wa::Message {
        let mut p = wa::message::ProtocolMessage::default();
        p.key = key(id);
        p.r#type = Some(wa::message::protocol_message::Type::REVOKE);
        let mut m = wa::Message::default();
        m.protocol_message = MessageField::some(p);
        m
    }

    fn react(id: &str, emoji: &str) -> wa::Message {
        let mut r = wa::message::ReactionMessage::default();
        r.key = key(id);
        r.text = Some(emoji.into());
        let mut m = wa::Message::default();
        m.reaction_message = MessageField::some(r);
        m
    }

    #[test]
    fn a_timer_change_without_a_key_is_read() {
        let mut p = wa::message::ProtocolMessage::default();
        p.r#type = Some(wa::message::protocol_message::Type::EPHEMERAL_SETTING);
        p.ephemeral_expiration = Some(0);
        let mut m = wa::Message::default();
        m.protocol_message = MessageField::some(p);
        let chat = "62811@s.whatsapp.net".to_owned();
        assert_eq!(
            Effect::parse(&m, chat.clone(), "me".into()),
            Some(Effect::Timer { chat, seconds: 0 })
        );
    }

    #[test]
    fn edits_deletes_and_reactions_apply_only_to_the_senders_message() {
        let path = std::env::temp_dir().join(format!("nimqo-effects-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let inbox = Inbox::open(&path, &Key::new([8; 32]), Fault::None).unwrap();
        let (g, ana, bob) = ("1-2@g.us", "ana@s.whatsapp.net", "bob@s.whatsapp.net");
        inbox.insert_for_test(g, ana, "m1");
        let effect = |m: wa::Message, by: &str| Effect::parse(&m, g.into(), by.into()).unwrap();
        let body = |inbox: &Inbox| {
            let m = &inbox.messages(g, 10).unwrap()[0];
            (
                m.kind.clone(),
                m.body.clone(),
                m.edited,
                m.reactions.clone(),
            )
        };

        // Bob cannot edit or delete Ana's message.
        inbox.apply_for_test(&[effect(edit("m1", "forged"), bob), effect(revoke("m1"), bob)]);
        assert_eq!(body(&inbox), ("text".into(), None, false, None));

        inbox.apply_for_test(&[effect(edit("m1", "fixed"), ana)]);
        assert_eq!(
            body(&inbox),
            ("text".into(), Some("fixed".into()), true, None)
        );

        inbox.apply_for_test(&[
            effect(react("m1", "👍"), bob),
            effect(react("m1", "❤️"), ana),
        ]);
        assert_eq!(body(&inbox).3.map(|r| r.chars().count()), Some(3)); // 👍 + ❤️ (2 scalars)
        inbox.apply_for_test(&[effect(react("m1", ""), bob)]);
        assert_eq!(body(&inbox).3.as_deref(), Some("❤️"));

        inbox.apply_for_test(&[effect(revoke("m1"), ana), effect(edit("m1", "again"), ana)]);
        assert_eq!(body(&inbox).0, "deleted");
        assert_eq!(body(&inbox).1, None, "no edits after a delete");
        drop(inbox);
        std::fs::remove_file(&path).unwrap();
    }
}
