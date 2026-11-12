//! A group's members, admins and description, asked of the server when the
//! user opens the group's info. Not stored, except the group's name.

use anyhow::{Result, anyhow};
use diesel::RunQueryDsl;
use diesel::sql_types::{Nullable, Text};
use whatsapp_rust::request::IqError;
use whatsapp_rust::{Client, GroupError, Jid, ParticipantType};

use crate::inbox::Inbox;
use crate::lids;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Role {
    Owner,
    Admin,
    Member,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Member {
    /// The member as the server addresses them, for admin actions.
    pub id: String,
    /// The account's own membership.
    pub is_me: bool,
    /// `+<digits>`, when the server or history disclosed it.
    pub phone: Option<String>,
    /// From the user's address book.
    pub saved_name: Option<String>,
    /// Self-chosen, so shown marked as such.
    pub push_name: Option<String>,
    pub role: Role,
}

#[derive(Debug, Clone)]
pub struct Info {
    pub subject: Option<String>,
    pub description: Option<String>,
    pub created_secs: Option<i64>,
    /// Only admins can send.
    pub announce_only: bool,
    /// Only admins can edit the group's info.
    pub locked: bool,
    pub members: Vec<Member>,
    /// The account's own role; None when it is no longer a member.
    pub my_role: Option<Role>,
}

/// Fetches the group's metadata and names its members from local contacts.
///
/// # Errors
/// Not a group id, or the server query fails.
pub async fn info(inbox: &Inbox, client: &Client, chat: &str) -> Result<Info> {
    let jid: Jid = chat.parse().map_err(|_| anyhow!("not a chat id"))?;
    if !chat.ends_with("@g.us") {
        return Err(anyhow!("not a group"));
    }
    let meta = match client.groups().fetch_metadata(&jid).await {
        Ok(meta) => meta,
        // The server keeps a group's info from those who left or were
        // removed: show it as a group the account is no longer in.
        Err(GroupError::Iq(IqError::ServerError { code, .. }))
            if [401, 403, 404].contains(&code) =>
        {
            return Ok(Info {
                subject: None,
                description: None,
                created_secs: None,
                announce_only: false,
                locked: false,
                members: Vec::new(),
                my_role: None,
            });
        }
        Err(e) => return Err(e.into()),
    };
    // Own number and LID, to find the account among the members.
    let me: Vec<Jid> = [client.pn(), client.lid()].into_iter().flatten().collect();
    let mut members = Vec::with_capacity(meta.participants.len());
    // Numbers learned for LIDs: mentions of them then read "+number".
    let mut learned = Vec::new();
    for p in &meta.participants {
        let id = match &p.phone_number {
            Some(pn) => pn.to_non_ad_string(),
            None => lids::phone_chat(inbox, client, &p.jid).await,
        };
        if let Some(lid) = [Some(&p.jid), p.lid.as_ref()]
            .into_iter()
            .flatten()
            .find(|j| j.is_lid())
            && id.ends_with("@s.whatsapp.net")
        {
            let lid = lid.to_non_ad_string();
            if inbox.known_pn(&lid).ok().flatten().as_deref() != Some(id.as_str()) {
                learned.push((lid, id.clone()));
            }
        }
        let lid = p.lid.as_ref().map(Jid::to_non_ad_string);
        let (saved_name, push_name) = inbox.member_names(&id, lid.as_deref())?;
        let is_me = [Some(&p.jid), p.phone_number.as_ref(), p.lid.as_ref()]
            .into_iter()
            .flatten()
            .any(|j| me.iter().any(|m| m.user == j.user));
        members.push(Member {
            id: p.jid.to_non_ad_string(),
            is_me,
            phone: id.strip_suffix("@s.whatsapp.net").map(|n| format!("+{n}")),
            saved_name,
            push_name,
            role: match p.participant_type {
                ParticipantType::SuperAdmin => Role::Owner,
                ParticipantType::Admin => Role::Admin,
                ParticipantType::Member => Role::Member,
            },
        });
    }
    if !learned.is_empty() {
        inbox.record_lids(&learned)?;
        inbox.notify_changed(vec![chat.to_owned()]);
    }
    sort(&mut members);
    let my_role = members.iter().find(|m| m.is_me).map(|m| m.role);
    if let Some(subject) = meta.subject.as_deref().filter(|s| !s.is_empty()) {
        inbox.set_chat_name(chat, subject)?;
    }
    Ok(Info {
        my_role,
        subject: meta.subject,
        description: meta.description.filter(|d| !d.trim().is_empty()),
        created_secs: meta.creation_time.and_then(|t| i64::try_from(t).ok()),
        announce_only: meta.is_announcement,
        locked: meta.is_locked,
        members,
    })
}

/// Owner, then admins, then members; saved names first, by name, then the
/// rest by number.
fn sort(members: &mut [Member]) {
    members.sort_by(|a, b| {
        let key = |m: &Member| {
            (
                m.role,
                m.saved_name.is_none(),
                m.saved_name.as_ref().map(|n| n.to_lowercase()),
                m.phone.clone(),
            )
        };
        key(a).cmp(&key(b))
    });
}

impl Inbox {
    /// The name the chat list shows for `chat` (a group's subject).
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn set_chat_name(&self, chat: &str, name: &str) -> Result<()> {
        let mut conn = self.lock()?;
        diesel::sql_query("INSERT OR REPLACE INTO chat_names (chat, name) VALUES (?, ?)")
            .bind::<Text, _>(chat)
            .bind::<Text, _>(name)
            .execute(&mut *conn)?;
        Ok(())
    }

    /// A member's saved name and push name, looked up by number and by LID.
    fn member_names(
        &self,
        id: &str,
        lid: Option<&str>,
    ) -> Result<(Option<String>, Option<String>)> {
        #[derive(diesel::QueryableByName)]
        struct Names {
            #[diesel(sql_type = Nullable<Text>)]
            saved: Option<String>,
            #[diesel(sql_type = Nullable<Text>)]
            push: Option<String>,
        }
        let lid = lid.unwrap_or(id);
        let mut conn = self.lock()?;
        let rows: Vec<Names> = diesel::sql_query(
            "SELECT coalesce((SELECT name FROM contacts WHERE jid IN (?1, ?2) LIMIT 1),
                             (SELECT name FROM chat_names WHERE chat = ?1)) AS saved,
                    (SELECT nullif(name, '') FROM push_names WHERE jid IN (?1, ?2) LIMIT 1) AS push",
        )
        .bind::<Text, _>(id)
        .bind::<Text, _>(lid)
        .load(&mut *conn)?;
        Ok(rows
            .into_iter()
            .next()
            .map_or((None, None), |r| (r.saved, r.push)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::inbox::Fault;
    use crate::vault::Key;

    fn member(role: Role, saved: Option<&str>, phone: &str) -> Member {
        Member {
            id: phone.into(),
            is_me: false,
            phone: Some(phone.into()),
            saved_name: saved.map(Into::into),
            push_name: None,
            role,
        }
    }

    #[test]
    fn owner_admins_then_saved_names_then_numbers() {
        let mut members = vec![
            member(Role::Member, None, "+3"),
            member(Role::Member, Some("bob"), "+2"),
            member(Role::Admin, None, "+9"),
            member(Role::Member, Some("Alice"), "+5"),
            member(Role::Owner, None, "+8"),
            member(Role::Member, None, "+1"),
        ];
        sort(&mut members);
        let order: Vec<_> = members
            .iter()
            .map(|m| m.phone.as_deref().unwrap())
            .collect();
        assert_eq!(order, ["+8", "+9", "+5", "+2", "+1", "+3"]);
    }

    #[test]
    fn names_come_from_contacts_and_push_names() {
        let path = std::env::temp_dir().join(format!("nimqo-groups-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let inbox = Inbox::open(&path, &Key::new([6; 32]), Fault::None).unwrap();
        inbox.save_contact("1@s.whatsapp.net", "Saved").unwrap();
        inbox
            .record_push_names(&[("9@lid".into(), "Pushed".into())])
            .unwrap();
        assert_eq!(
            inbox
                .member_names("1@s.whatsapp.net", Some("9@lid"))
                .unwrap(),
            (Some("Saved".into()), Some("Pushed".into()))
        );
        assert_eq!(
            inbox.member_names("2@s.whatsapp.net", None).unwrap(),
            (None, None)
        );
    }
}
