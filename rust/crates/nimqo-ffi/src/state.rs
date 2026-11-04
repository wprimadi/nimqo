//! Connection state machine (plan 10.1). Pure: inputs in, next state out,
//! so every transition is unit tested without a network.

/// What the app shows. Terminal states stay until the user acts (re-pair,
/// update); the core does not try to leave them on its own.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ConnectionState {
    Connecting,
    /// Showing QR codes for a device that is not linked yet.
    Pairing,
    /// QR codes ran out before a scan; pairing must be restarted.
    NotPaired,
    Connected,
    Reconnecting,
    /// No network path. Reconnects wait for it instead of failing.
    Offline,
    LoggedOut,
    /// Another session took over this device; do not fight it in a loop.
    StreamReplaced,
    TemporaryBan {
        expires_in_secs: u64,
    },
    ClientOutdated,
    Failed {
        reason: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Input {
    QrShown,
    QrExhausted,
    Connected,
    Disconnected,
    LoggedOut,
    StreamReplaced,
    TemporaryBan {
        expires_in_secs: u64,
    },
    ClientOutdated,
    /// `ConnectFailure` that upstream classifies; `retry` means transient.
    ConnectFailure {
        logged_out: bool,
        retry: bool,
        reason: String,
    },
    StreamError {
        code: String,
    },
    NetworkLost,
    NetworkRestored,
}

impl ConnectionState {
    #[must_use]
    pub fn is_terminal(&self) -> bool {
        matches!(
            self,
            Self::LoggedOut
                | Self::StreamReplaced
                | Self::TemporaryBan { .. }
                | Self::ClientOutdated
                | Self::Failed { .. }
        )
    }

    #[must_use]
    pub fn next(&self, input: Input) -> Self {
        use ConnectionState as S;
        if self.is_terminal() {
            return self.clone();
        }
        match input {
            Input::LoggedOut
            | Input::ConnectFailure {
                logged_out: true, ..
            } => S::LoggedOut,
            Input::StreamReplaced => S::StreamReplaced,
            Input::TemporaryBan { expires_in_secs } => S::TemporaryBan { expires_in_secs },
            Input::ClientOutdated => S::ClientOutdated,
            Input::ConnectFailure {
                retry: false,
                reason,
                ..
            } => S::Failed { reason },
            Input::NetworkLost => S::Offline,
            // While offline, upstream's own retries are expected to fail.
            _ if *self == S::Offline
                && input != Input::NetworkRestored
                && input != Input::Connected =>
            {
                S::Offline
            }
            Input::NetworkRestored => S::Reconnecting,
            Input::QrShown => S::Pairing,
            Input::QrExhausted => S::NotPaired,
            Input::Connected => S::Connected,
            Input::Disconnected
            | Input::StreamError { .. }
            | Input::ConnectFailure { retry: true, .. } => {
                match self {
                    // A first connection that drops is still connecting.
                    S::Connecting | S::Pairing | S::NotPaired => self.clone(),
                    _ => S::Reconnecting,
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{ConnectionState as S, Input as I};

    fn run(inputs: impl IntoIterator<Item = I>) -> S {
        inputs.into_iter().fold(S::Connecting, |s, i| s.next(i))
    }

    #[test]
    fn stored_session_connects_and_survives_drops() {
        assert_eq!(run([I::Connected]), S::Connected);
        assert_eq!(run([I::Connected, I::Disconnected]), S::Reconnecting);
        assert_eq!(
            run([I::Connected, I::Disconnected, I::Connected]),
            S::Connected
        );
        assert_eq!(
            run([I::Connected, I::StreamError { code: "515".into() }]),
            S::Reconnecting
        );
    }

    #[test]
    fn pairing_flow() {
        assert_eq!(run([I::QrShown]), S::Pairing);
        assert_eq!(run([I::QrShown, I::Connected]), S::Connected);
        assert_eq!(run([I::QrShown, I::QrExhausted]), S::NotPaired);
        assert_eq!(run([I::QrShown, I::Disconnected]), S::Pairing);
    }

    #[test]
    fn offline_pauses_until_the_network_returns() {
        let off = run([I::Connected, I::NetworkLost]);
        assert_eq!(off, S::Offline);
        assert_eq!(off.next(I::Disconnected), S::Offline);
        let retry = I::ConnectFailure {
            logged_out: false,
            retry: true,
            reason: String::new(),
        };
        assert_eq!(off.next(retry), S::Offline);
        assert_eq!(off.next(I::NetworkRestored), S::Reconnecting);
        assert_eq!(off.next(I::Connected), S::Connected);
    }

    #[test]
    fn terminal_states_are_sticky() {
        let ban = run([
            I::Connected,
            I::TemporaryBan {
                expires_in_secs: 60,
            },
        ]);
        assert_eq!(
            ban,
            S::TemporaryBan {
                expires_in_secs: 60
            }
        );
        for s in [
            ban,
            run([I::LoggedOut]),
            run([I::StreamReplaced]),
            run([I::ClientOutdated]),
            run([I::ConnectFailure {
                logged_out: true,
                retry: false,
                reason: String::new(),
            }]),
            run([I::ConnectFailure {
                logged_out: false,
                retry: false,
                reason: "403".into(),
            }]),
        ] {
            assert!(s.is_terminal(), "{s:?}");
            assert_eq!(s.next(I::Connected), s);
            assert_eq!(s.next(I::NetworkRestored), s);
        }
    }
}
