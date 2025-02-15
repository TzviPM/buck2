/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under both the MIT license found in the
 * LICENSE-MIT file in the root directory of this source tree and the Apache
 * License, Version 2.0 found in the LICENSE-APACHE file in the root directory
 * of this source tree.
 */

use std::future::Future;
use std::pin::Pin;
use std::task::Poll;

use futures::future::BoxFuture;
use futures::FutureExt;
use more_futures::instrumented_shared::SharedEventsFuture;
use more_futures::spawn::StrongJoinHandle;
use more_futures::spawn::WeakFutureError;

use crate::legacy::incremental::graph::storage_properties::StorageProperties;
use crate::result::CancellableResult;
use crate::GraphNode;

type DiceJoinHandle<S> = StrongJoinHandle<
    SharedEventsFuture<
        BoxFuture<'static, Result<CancellableResult<GraphNode<S>>, WeakFutureError>>,
    >,
>;

pub(crate) enum DiceFuture<S: StorageProperties> {
    /// Earlier computed value.
    Ready(Option<GraphNode<S>>),
    /// Current computation spawned the task.
    AsyncCancellableSpawned(DiceJoinHandle<S>),
    /// Other computation for current key spawned the task.
    AsyncCancellableJoining(DiceJoinHandle<S>),
}

impl<S> Future for DiceFuture<S>
where
    S: StorageProperties,
{
    type Output = GraphNode<S>;

    fn poll(self: Pin<&mut Self>, cx: &mut std::task::Context<'_>) -> Poll<Self::Output> {
        match self.get_mut() {
            DiceFuture::Ready(value) => Poll::Ready(value.take().expect("polled after ready")),
            DiceFuture::AsyncCancellableSpawned(fut) | DiceFuture::AsyncCancellableJoining(fut) => {
                Pin::new(&mut fut.map(|cancellable| match cancellable {
                    Ok(res) => res,
                    Err(_) => {
                        unreachable!("Strong Join Handle was cancelled while still polled")
                    }
                }))
                .poll(cx)
            }
        }
    }
}
