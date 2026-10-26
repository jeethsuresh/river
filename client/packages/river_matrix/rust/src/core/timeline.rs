use super::connection::{MatrixCore, sdk_error};
use anyhow::{Context, Result, ensure};
use matrix_sdk::{
    room::{IncludeRelations, RelationsOptions},
    ruma::{EventId, events::relation::RelationType},
};
use serde_json::{Value, json};

impl MatrixCore {
    pub async fn thread(
        &self,
        room: String,
        event: String,
        cursor: Option<String>,
    ) -> Result<String> {
        let room = self.room(&room)?;
        let event = EventId::parse(event)?;
        let root = room.event(&event, None).await.map_err(sdk_error)?;
        let mut root: Value = serde_json::from_str(root.raw().json().get())?;
        root["room_id"] = json!(room.room_id());
        let options = RelationsOptions {
            from: cursor,
            limit: Some(50u32.into()),
            include_relations: IncludeRelations::RelationsOfType(RelationType::Thread),
            ..Default::default()
        };
        let page = room.relations(event, options).await.map_err(sdk_error)?;
        let events: Result<Vec<Value>> = page
            .chunk
            .into_iter()
            .rev()
            .map(|event| {
                let mut value: Value = serde_json::from_str(event.raw().json().get())?;
                value["room_id"] = json!(room.room_id());
                value["river_encrypted"] = json!(event.encryption_info().is_some());
                Ok(value)
            })
            .collect();
        Ok(json!({"root":root,"events":events?,"next_cursor":page.next_batch_token}).to_string())
    }

    pub(crate) async fn reaction(&self, data: &Value) -> Result<()> {
        let room_id = data["room"].as_str().context("Missing room")?;
        let room = self.room(room_id)?;
        let event = EventId::parse(data["event"].as_str().context("Missing event")?)?;
        let key = data["key"].as_str().context("Missing reaction")?;
        ensure!(!key.is_empty() && key.len() <= 128, "Invalid reaction");
        let mut own = Vec::new();
        let mut cursor = None;
        for page_index in 0..10 {
            let page = room
                .relations(
                    event.clone(),
                    RelationsOptions {
                        from: cursor,
                        limit: Some(100u32.into()),
                        include_relations: IncludeRelations::RelationsOfType(
                            RelationType::Annotation,
                        ),
                        ..Default::default()
                    },
                )
                .await
                .map_err(sdk_error)?;
            for reaction in page.chunk {
                let value: Value = serde_json::from_str(reaction.raw().json().get())?;
                if value["sender"] == self.own_user.as_str()
                    && value["type"] == "m.reaction"
                    && value["content"]["m.relates_to"]["key"] == key
                {
                    if let Some(id) = value["event_id"].as_str() {
                        own.push(EventId::parse(id)?);
                    }
                }
            }
            cursor = page.next_batch_token;
            if cursor.is_none() {
                break;
            }
            ensure!(
                page_index < 9,
                "Too many reactions. Try again after refreshing."
            );
        }
        if data["active"]
            .as_bool()
            .context("Missing desired reaction state")?
        {
            if own.is_empty() {
                self.send(
                    room_id.to_owned(),
                    "m.reaction".into(),
                    json!({"m.relates_to":{
                    "rel_type":"m.annotation","event_id":event,"key":key}})
                    .to_string(),
                    data["transaction"]
                        .as_str()
                        .context("Missing transaction")?
                        .to_owned(),
                )
                .await?;
            }
        } else {
            for id in own {
                room.redact(&id, None, None).await.map_err(sdk_error)?;
            }
        }
        Ok(())
    }

    pub(crate) async fn edit(&self, data: &Value) -> Result<()> {
        let room_id = data["room"].as_str().context("Missing room")?;
        let room = self.room(room_id)?;
        let event = EventId::parse(data["event"].as_str().context("Missing event")?)?;
        let original = room.event(&event, None).await.map_err(sdk_error)?;
        let original: Value = serde_json::from_str(original.raw().json().get())?;
        ensure!(
            original["sender"] == self.own_user.as_str(),
            "Only the sender can edit this message"
        );
        let event_type = original["type"]
            .as_str()
            .context("Invalid original message")?;
        ensure!(
            event_type != "m.room.encrypted",
            "Recover the original message keys before editing"
        );
        let mut content = original["content"].clone();
        ensure!(content.is_object(), "Invalid message content");
        content["body"] = data["body"].clone();
        if data["title"].is_string() {
            content["title"] = data["title"].clone();
        }
        let mut replacement = content.clone();
        replacement["body"] = json!(format!(
            "* {}",
            data["body"].as_str().context("Missing message")?
        ));
        replacement["m.new_content"] = content;
        replacement["m.relates_to"] = json!({"rel_type":"m.replace","event_id":event});
        self.send(
            room_id.to_owned(),
            event_type.to_owned(),
            replacement.to_string(),
            data["transaction"]
                .as_str()
                .context("Missing transaction")?
                .to_owned(),
        )
        .await?;
        Ok(())
    }
}
