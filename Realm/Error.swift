////////////////////////////////////////////////////////////////////////////
//
// Copyright 2014 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

import Realm

extension Realm {
    /**
    Enumeration that describes the error codes within the Realm error domain.
    The returned instances can be used to catch a variety of _recoverable_ errors, especially those
    happening when initializing a Realm instance.
    
        let realm: Realm?
        do {
            realm = Realm()
        } catch Realm.Error.IncompatibleLockFile() {
            print("Realm Browse app may be attached to Realm on device?")
        }

    */
    public struct Error : ErrorType {
        /**
        Implementation of hidden requirement by `ErrorType`.

        - returns: the rawValue of a `RLMError` case.
        */
        public let _code: Int

        /**
        Implementation of hidden requirement by `ErrorType`.

        - returns: `RLMErrorDomain`.
        */
        public var _domain: String {
            return RLMErrorDomain
        }

        /**
        This initializer is private, because instances of this struct should be only for comparison,
        when catching errors.
        */
        private init(code: RLMError) {
            self._code = code.rawValue
        }

        /**
        - returns: error thrown by RLMRealm if no other specific error is returned when a realm is opened.
        */
        public static func Fail() -> Error {
            return Error(code: RLMError.Fail)
        }

        /**
        - returns: error thrown by RLMRealm for any I/O related exception scenarios when a realm is opened.
        */
        public static func FileAccessError() -> Error {
            return Error(code: RLMError.FileAccessError)
        }

        /**
        - returns: error thrown by RLMRealm if the user does not have permission to open or create
                   the specified file in the specified access mode when the realm is opened.
        */
        public static func FilePermissionDenied() -> Error {
            return Error(code: RLMError.FilePermissionDenied)
        }

        /**
        - returns: error thrown by RLMRealm if no_create was specified and the file did already exist
                   when the realm is opened.
        */
        public static func FileExists() -> Error {
            return Error(code: RLMError.FileExists)
        }

        /**
        - returns: error thrown by RLMRealm if no_create was specified and the file was not found
                   when the realm is opened.
        */
        public static func FileNotFound() -> Error {
            return Error(code: RLMError.FileNotFound)
        }

        /**
        - returns: error thrown by RLMRealm if the database file is currently open in another process which
                   cannot share with the current process due to an architecture mismatch.
        */
        public static func IncompatibleLockFile() -> Error {
            return Error(code: RLMError.IncompatibleLockFile)
        }
    }
}

/**
Explicitly implement pattern matching for `Realm.Error`, so that the instances can be used in the
`do … syntax`.
*/
public func ~=(lhs: Realm.Error, rhs: ErrorType) -> Bool {
    return lhs._code == rhs._code
        && lhs._domain == rhs._domain
}
