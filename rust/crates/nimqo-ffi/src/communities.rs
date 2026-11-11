//! Communities the account is in and the groups inside them, asked of the
//! server when shown. Nothing is stored; joining a group is the one write.

use std::collections::HashSet;
use std::sync::Arc;

use whatsapp_rust::Jid;
use whatsapp_rust::features::CommunityError;

use crate::{Core, CoreError};

#[derive(Debug, uniffi::Record)]
pub struct Community {
    pub id: String,
    pub name: String,
    pub members: Option<u32>,
}

#[derive(Debug, uniffi::Record)]
pub struct CommunityGroup {
    pub id: String,
    pub name: String,
    pub members: Option<u32>,
    /// The community's announcement group, where only admins post.
    pub announcements: bool,
    /// The account is a member: the group opens as a chat.
    pub joined: bool,
}

/// Shown to the user when a join does not go through.
fn refused(e: &CommunityError) -> CoreError {
    log::info!("community group not joined: {e}");
    let reason = match e {
        CommunityError::MembershipApprovalRequired(_) => {
            "Asked to join. An admin of the community has to approve it."
        }
        _ => "Couldn't join the group. Check the connection and try again.",
    };
    CoreError::SendRefused {
        reason: reason.into(),
    }
}

#[uniffi::export]
impl Core {
    /// The communities this account is in, by name. Nil when offline.
    pub async fn communities(&self) -> Option<Vec<Community>> {
        let client = Arc::clone(&self.client);
        let fetched = self
            .runtime
            .spawn(async move { client.community().list_participating().await })
            .await;
        match fetched {
            Ok(Ok(list)) => {
                log::info!("communities: {}", list.len());
                let mut list: Vec<_> = list
                    .into_iter()
                    .map(|c| Community {
                        id: c.id.to_string(),
                        name: c.subject.unwrap_or_default(),
                        members: c.participant_count,
                    })
                    .collect();
                list.sort_by_cached_key(|c| c.name.to_lowercase());
                Some(list)
            }
            Ok(Err(e)) => {
                log::info!("communities not fetched: {e}");
                None
            }
            Err(e) => {
                log::warn!("communities task failed: {e}");
                None
            }
        }
    }

    /// The groups of a community this account can see: announcements first,
    /// then the rest by name. Nil when offline.
    pub async fn community_groups(&self, community_id: String) -> Option<Vec<CommunityGroup>> {
        let client = Arc::clone(&self.client);
        let fetched = self
            .runtime
            .spawn(async move {
                let jid: Jid = community_id.parse().map_err(|_| None)?;
                let groups = client
                    .community()
                    .get_subgroups(&jid)
                    .await
                    .map_err(|e| Some(e.to_string()))?;
                let mine: HashSet<_> = client
                    .groups()
                    .list_participating()
                    .await
                    .map_err(|e| Some(e.to_string()))?
                    .into_iter()
                    .map(|g| g.id)
                    .collect();
                Ok::<_, Option<String>>((groups, mine))
            })
            .await;
        let (groups, mine) = match fetched {
            Ok(Ok(found)) => found,
            Ok(Err(e)) => {
                log::info!("community groups not fetched: {}", e.unwrap_or_default());
                return None;
            }
            Err(e) => {
                log::warn!("community groups task failed: {e}");
                return None;
            }
        };
        let mut list: Vec<_> = groups
            .into_iter()
            .map(|g| CommunityGroup {
                joined: mine.contains(&g.id),
                id: g.id.to_string(),
                name: g.subject,
                members: g.participant_count,
                announcements: g.is_default_sub_group,
            })
            .collect();
        list.sort_by_cached_key(|g| (!g.announcements, g.name.to_lowercase()));
        Some(list)
    }

    /// Joins one of a community's groups.
    ///
    /// # Errors
    /// `SendRefused` with a reason to show: the join needs an admin's
    /// approval, or it failed.
    pub async fn join_community_group(
        &self,
        community_id: String,
        group_id: String,
    ) -> Result<(), CoreError> {
        let client = Arc::clone(&self.client);
        self.on_runtime(async move {
            let (Ok(community), Ok(group)) = (community_id.parse::<Jid>(), group_id.parse::<Jid>())
            else {
                return Err(CoreError::SendRefused {
                    reason: "Not a community group.".into(),
                });
            };
            client
                .community()
                .join_subgroup(community, group)
                .await
                .map(|_| ())
                .map_err(|e| refused(&e))
        })
        .await
    }
}
