# frozen_string_literal: true

# Copyright 2016 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require "thor"

# Base command line module for samples. Provides authorization support,
# either using application default credentials or user authorization
# depending on the use case.
module GoogleTasks
  class BaseCli < Thor
    include Thor::Actions
    include AuthorizationHelpers

    class_option :user, type: :string
    class_option :api_key, type: :string
  end
end
