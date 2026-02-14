use crate::event::{ActorId, MsgId, NodeId};

#[derive(Debug, Clone)]
pub struct PendingDelivery {
    pub node: NodeId,
    pub to: ActorId,
    pub msg_id: MsgId,
}

fn delivery_key(d: &PendingDelivery) -> (NodeId, ActorId, MsgId) {
    (d.node, d.to, d.msg_id)
}

pub fn choose_next_deterministic(mut pending: Vec<PendingDelivery>) -> Option<PendingDelivery> {
    if pending.is_empty() {
        return None;
    }
    pending.sort_by_key(delivery_key);
    Some(pending.remove(0))
}

#[cfg(test)]
mod tests {
    use super::{choose_next_deterministic, PendingDelivery};
    use uuid::Uuid;

    #[test]
    fn chooses_lexicographically_smallest_delivery() {
        let node = Uuid::parse_str("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa").unwrap();
        let to_a = Uuid::parse_str("11111111-1111-1111-1111-111111111111").unwrap();
        let to_b = Uuid::parse_str("22222222-2222-2222-2222-222222222222").unwrap();
        let m1 = Uuid::parse_str("00000000-0000-0000-0000-000000000001").unwrap();
        let m2 = Uuid::parse_str("00000000-0000-0000-0000-000000000002").unwrap();

        let pending = vec![
            PendingDelivery {
                node,
                to: to_b,
                msg_id: m2,
            },
            PendingDelivery {
                node,
                to: to_a,
                msg_id: m1,
            },
        ];

        let chosen = choose_next_deterministic(pending).expect("delivery should be chosen");
        assert_eq!(chosen.to, to_a);
        assert_eq!(chosen.msg_id, m1);
    }
}
