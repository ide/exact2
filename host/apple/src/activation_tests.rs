//! A data source that isn't ready at activation wakes the session when it is.

use super::*;
use exact_kernel::MonospaceMeasurer;
use exact_plan::{builder::PlanBuilder, Value};
use exact_runner::DataError;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

type Wake = Box<dyn FnOnce() + Send>;

/// Prepares in the background until `ready`; keeps the wake it is given.
struct Loading {
    ready: Arc<AtomicBool>,
    waiting: Arc<Mutex<Option<Wake>>>,
}
impl DataSource for Loading {
    fn app_id(&self) -> &str {
        "test.exact.activation"
    }
    fn query(&mut self, name: &str, _: &[Value]) -> Result<Value, DataError> {
        Err(DataError::UnknownSource(name.into()))
    }
    fn preload(&self) -> Result<bool, DataError> {
        Ok(self.ready.load(Ordering::SeqCst))
    }
    fn when_preloaded(&self, wake: Wake) {
        *self.waiting.lock().unwrap() = Some(wake);
    }
}

#[test]
fn a_pending_activation_wakes_the_session_once_the_source_is_ready() {
    let mut builder = PlanBuilder::new(exact_kernel::SCHEMA_DIGEST, 1);
    builder.node(NodeType::View as u8, None, None, 0, &[], &[], None);
    let plan = builder.finish().unwrap().encode();
    let (ready, waiting) = (Arc::new(AtomicBool::new(false)), Arc::new(Mutex::new(None)));
    let source = Loading {
        ready: ready.clone(),
        waiting: waiting.clone(),
    };
    let (mut host, _) = Host::boot(
        &plan,
        source,
        Box::new(MonospaceMeasurer::default()),
        10.0,
        10.0,
    )
    .unwrap();
    let wakes = Arc::new(AtomicUsize::new(0));
    let counted = wakes.clone();
    host.listen(Arc::new(move || {
        counted.fetch_add(1, Ordering::SeqCst);
    }));
    assert!(host.activate_data().contains("\"pending\":true"));
    let wake = waiting
        .lock()
        .unwrap()
        .take()
        .expect("the source holds the session's wake");
    assert_eq!(
        wakes.load(Ordering::SeqCst),
        0,
        "no wake before the source is ready"
    );
    ready.store(true, Ordering::SeqCst);
    wake();
    assert_eq!(wakes.load(Ordering::SeqCst), 1, "the session is woken");
    assert!(
        !host.activate_data().contains("\"pending\":true"),
        "and activates"
    );
}
