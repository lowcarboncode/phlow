pub mod context;
pub mod count;
pub mod id;
pub mod modules;
pub mod otel;
use context::Context;
pub use crossbeam;
use crossbeam::channel;
use modules::ModulePackage;
pub use opentelemetry;
use std::collections::HashMap;
use std::fmt::{Debug, Formatter};
pub use tokio;
use tokio::sync::oneshot;
pub use tracing;
pub use tracing_core;
pub use tracing_opentelemetry;
pub use tracing_subscriber;
pub use valu3;
use valu3::{traits::ToValueBehavior, value::Value};

pub type ModuleId = usize;
pub type MainRuntimeSender = channel::Sender<Package>;
pub type ModuleSetupSender = oneshot::Sender<Option<channel::Sender<ModulePackage>>>;

#[derive(Debug)]
pub struct ModuleSetup {
    pub id: ModuleId,
    pub setup_sender: ModuleSetupSender,
    pub main_sender: Option<MainRuntimeSender>,
    pub with: Value,
    pub dispatch: tracing::Dispatch,
}

impl ModuleSetup {
    pub fn is_main(&self) -> bool {
        self.main_sender.is_some()
    }
}

#[derive(Default)]
pub struct Package {
    pub send: Option<oneshot::Sender<Value>>,
    pub request_data: Option<Value>,
    pub origin: ModuleId,
    pub span: Option<tracing::Span>,
    pub dispatch: Option<tracing::Dispatch>,
}

// Only production mode
impl Debug for Package {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        let map: HashMap<_, _> = vec![
            ("request_data", self.request_data.to_value()),
            ("step_position", self.origin.to_value()),
        ]
        .into_iter()
        .collect();

        write!(
            f,
            "{}",
            map.to_value().to_json(valu3::prelude::JsonMode::Inline)
        )
    }
}

impl Package {
    pub fn get_data(&self) -> Option<&Value> {
        self.request_data.as_ref()
    }

    pub fn send(&mut self, response_data: Value) {
        if let Some(send) = self.send.take() {
            sender_safe!(send, response_data);
        }
    }
}

#[macro_export]
macro_rules! span_enter {
    ($span:expr) => {
        let span_enter_clone = $span.clone();
        let _enter = span_enter_clone.enter();
    };
}

#[macro_export]
macro_rules! sender_safe {
    ($sender:expr, $data:expr) => {
        if let Err(err) = $sender.send($data) {
            $crate::tracing::debug!("Error sending data: {:?}", err);
        }
    };
}

#[macro_export]
macro_rules! otlp_start {
    () => {
        let _ = match phlow_sdk::otel::init_tracing_subscriber_plugin() {
            Ok(guard) => guard,
            Err(e) => {
                $crate::tracing::error!("Error creating tracing subscriber: {:?}", e);
                return;
            }
        };
    };
}

#[macro_export]
macro_rules! plugin {
    ($handler:ident) => {
        #[no_mangle]
        pub extern "C" fn plugin(setup: ModuleSetup) {
            match $handler(setup) {
                Ok(_) => {}
                Err(e) => {
                    $crate::tracing::error!("Error in plugin: {:?}", e);
                }
            }
        }
    };
}

#[macro_export]
macro_rules! plugin_async {
    ($handler:ident) => {
        #[no_mangle]
        pub extern "C" fn plugin(setup: ModuleSetup) {
            if let Ok(rt) = tokio::runtime::Runtime::new() {
                if let Err(e) = rt.block_on($handler(setup)) {
                    phlow_sdk::tracing::error!("Error in plugin: {:?}", e);
                }
            } else {
                phlow_sdk::tracing::error!("Error creating runtime");
                return;
            };
        }
    };
}
#[macro_export]
macro_rules! main_plugin_async {
    ($handler:ident) => {
        #[no_mangle]
        pub extern "C" fn plugin(setup: ModuleSetup) {
            let dispatch = setup.dispatch.clone();
            phlow_sdk::tracing::dispatcher::with_default(&dispatch, || {
                let _guard = phlow_sdk::otel::init_tracing_subscriber();

                if let Ok(rt) = phlow_sdk::tokio::runtime::Runtime::new() {
                    rt.block_on(start_server(setup)).unwrap_or_else(|e| {
                        phlow_sdk::tracing::error!("Error in plugin: {:?}", e);
                    });
                    println!("Plugin loaded");
                } else {
                    phlow_sdk::tracing::error!("Error creating runtime");
                    println!("Plugin loaded");

                    return;
                };

                println!("Plugin loaded");
            });
        }
    };
}

#[macro_export]
macro_rules! sender_without_response {
    ($id:expr, $sender:expr, $data:expr) => {{
        let package = Package {
            send: None,
            request_data: $data,
            origin: $id,
        };

        sender_safe!($sender, package);
    }};
}

#[macro_export]
macro_rules! sender {
    ($id:expr, $sender:expr, $data:expr) => {{
        let (tx, rx) = tokio::sync::oneshot::channel::<valu3::value::Value>();

        let package = Package {
            send: Some(tx),
            request_data: $data,
            origin: $id,
            span: None,
            dispatch: None,
        };

        sender_safe!($sender, package);

        rx
    }};
    ($span:expr, $dispatch:expr, $id:expr, $sender:expr, $data:expr) => {{
        let (tx, rx) = tokio::sync::oneshot::channel::<valu3::value::Value>();

        let package = Package {
            send: Some(tx),
            request_data: $data,
            origin: $id,
            span: Some($span),
            dispatch: Some($dispatch),
        };

        sender_safe!($sender, package);

        rx
    }};
}

pub mod prelude {
    pub use crate::plugin;
    pub use crate::*;
    pub use valu3::json;
    pub use valu3::prelude::*;
}
