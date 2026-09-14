use serde::Serialize;
use std::fmt::{Display, Formatter};

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PreserveError {
    pub code: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub state_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub route_id: Option<String>,
}

impl PreserveError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            state_id: None,
            route_id: None,
        }
    }

    pub fn context(mut self, state_id: &str, route_id: Option<&str>) -> Self {
        self.state_id = Some(state_id.to_owned());
        self.route_id = route_id.map(str::to_owned);
        self
    }
}

impl Display for PreserveError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for PreserveError {}

pub type Result<T> = std::result::Result<T, PreserveError>;
