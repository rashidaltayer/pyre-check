(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)


val find_sources: ?filter: (string -> bool) -> Configuration.Analysis.t -> Pyre.Path.t list
val find_stubs: configuration: Configuration.Analysis.t -> Pyre.Path.t list

val parse_sources
  :  configuration: Configuration.Analysis.t
  -> scheduler: Scheduler.t
  -> files: File.t list
  -> File.Handle.t list

type result = {
  stubs: File.Handle.t list;
  sources: File.Handle.t list;
}

val parse_all: Scheduler.t -> configuration: Configuration.Analysis.t -> result
