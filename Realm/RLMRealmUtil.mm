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

#import "RLMRealmUtil.hpp"

#import "RLMRealm_Private.hpp"

#import "realm_delegate.hpp"

#import <map>
#import <mutex>
#import <sys/event.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <unistd.h>

// Global realm state
static std::mutex s_realmCacheMutex;
static std::map<std::string, NSMapTable *> s_realmsPerPath;

void RLMCacheRealm(std::string const& path, RLMRealm *realm) {
    std::lock_guard<std::mutex> lock(s_realmCacheMutex);
    NSMapTable *realms = s_realmsPerPath[path];
    if (!realms) {
        s_realmsPerPath[path] = realms = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPersonality
                                                               valueOptions:NSPointerFunctionsWeakMemory];
    }
    [realms setObject:realm forKey:@(pthread_mach_thread_np(pthread_self()))];
}

RLMRealm *RLMGetAnyCachedRealmForPath(std::string const& path) {
    std::lock_guard<std::mutex> lock(s_realmCacheMutex);
    return [s_realmsPerPath[path] objectEnumerator].nextObject;
}

RLMRealm *RLMGetThreadLocalCachedRealmForPath(std::string const& path) {
    mach_port_t threadID = pthread_mach_thread_np(pthread_self());
    std::lock_guard<std::mutex> lock(s_realmCacheMutex);
    return [s_realmsPerPath[path] objectForKey:@(threadID)];
}

void RLMClearRealmCache() {
    std::lock_guard<std::mutex> lock(s_realmCacheMutex);
    s_realmsPerPath.clear();
}

void RLMInstallUncaughtExceptionHandler() {
    static auto previousHandler = NSGetUncaughtExceptionHandler();

    NSSetUncaughtExceptionHandler([](NSException *exception) {
        NSNumber *threadID = @(pthread_mach_thread_np(pthread_self()));
        {
            std::lock_guard<std::mutex> lock(s_realmCacheMutex);
            for (auto const& realmsPerThread : s_realmsPerPath) {
                if (RLMRealm *realm = [realmsPerThread.second objectForKey:threadID]) {
                    if (realm.inWriteTransaction) {
                        [realm cancelWriteTransaction];
                    }
                }
            }
        }
        if (previousHandler) {
            previousHandler(exception);
        }
    });
}

// Convert an error code to either an NSError or an exception
static void handleError(int err, NSError **error) {
    if (!error) {
        @throw RLMException(@(strerror(err)));
    }
    *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:nil];
}

// Write a byte to a pipe to notify anyone waiting for data on the pipe
static void notifyFd(int fd) {
    while (true) {
        char c = 0;
        ssize_t ret = write(fd, &c, 1);
        if (ret == 1) {
            break;
        }

        // If the pipe's buffer is full, we need to read some of the old data in
        // it to make space. We don't just read in the code waiting for
        // notifications so that we can notify multiple waiters with a single
        // write.
        assert(ret == -1 && errno == EAGAIN);
        char buff[1024];
        read(fd, buff, sizeof buff);
    }
}

namespace {
// A RAII holder for a file descriptor which automatically closes the wrapped fd
// when it's deallocated
class FdHolder {
    int fd = -1;
    void close() {
        if (fd != -1) {
            ::close(fd);
        }
        fd = -1;
    }

    FdHolder& operator=(FdHolder const&) = delete;
    FdHolder(FdHolder const&) = delete;

public:
    FdHolder() = default;
    ~FdHolder() { close(); }
    operator int() const { return fd; }

    FdHolder& operator=(int newFd) {
        close();
        fd = newFd;
        return *this;
    }
};

// Inter-thread and inter-process notifications of changes are done using a
// named pipe in the filesystem next to the Realm file. Everyone who wants to be
// notified of commits waits for data to become available on the pipe, and anyone
// who commits a write transaction writes data to the pipe after releasing the
// write lock. Note that no one ever actually *reads* from the pipe: the data
// actually written is meaningless, and trying to read from a pipe from multiple
// processes at once is fraught with race conditions.

// When a RLMRealm instance is created, we add a CFRunLoopSource to the current
// thread's runloop. On each cycle of the run loop, the run loop checks each of
// its sources for work to do, which in the case of CFRunLoopSource is just
// checking if CFRunLoopSourceSignal has been called since the last time it ran,
// and if so invokes the function pointer supplied when the source is created,
// which in our case just invokes `[realm handleExternalChange]`.

// Listening for external changes is done using kqueue() on a background thread.
// kqueue() lets us efficiently wait until the amount of data which can be read
// from one or more file descriptors has changed, and tells us which of the file
// descriptors it was that changed. We use this to wait on both the shared named
// pipe, and a local anonymous pipe. When data is written to the named pipe, we
// signal the runloop source and wake up the target runloop, and when data is
// written to the anonymous pipe the background thread removes the runloop
// source from the runloop and and shuts down.

class RLMNotificationHelper : public realm::RealmDelegate {
public:
    RLMNotificationHelper(RLMRealm *realm, NSError **error);

    ~RLMNotificationHelper() {
        notifyFd(_shutdownWriteFd);
        pthread_join(_thread, nullptr); // Wait for the thread to exit
    }

    void transaction_committed() override {
        notifyFd(_notifyFd);
    }

    void changes_available() override {
        [_realm sendNotifications:RLMRealmRefreshRequiredNotification];
    }

    std::vector<ObserverState> get_observed_rows() override {
        return {};
    }

    void will_change(std::vector<ObserverState> const&, std::vector<void*> const&) override {

    }

    void did_change(std::vector<ObserverState> const&, std::vector<void*> const&) override {
        [_realm sendNotifications:RLMRealmDidChangeNotification];
    }

    void listen();

private:
    // This is owned by the realm, so it needs to not retain the realm
    __unsafe_unretained RLMRealm *const _realm;

    // Runloop which notifications are delivered on
    CFRunLoopRef _runLoop;

    // The listener thread
    pthread_t _thread;

    // Read-write file descriptor for the named pipe which is waited on for
    // changes and written to when a commit is made
    FdHolder _notifyFd;
    // File descriptor for the kqueue
    FdHolder _kq;
    // The two ends of an anonymous pipe used to notify the kqueue() thread that
    // it should be shut down.
    FdHolder _shutdownReadFd;
    FdHolder _shutdownWriteFd;
};
} // anonymous namespace

RLMNotificationHelper::RLMNotificationHelper(RLMRealm *realm, NSError **error)
: _realm(realm)
, _runLoop(CFRunLoopGetCurrent())
{
    CFRetain(_runLoop);

    _kq = kqueue();
    if (_kq == -1) {
        handleError(errno, error);
        return;
    }

    const char *path = [realm.path stringByAppendingString:@".note"].UTF8String;

    // Create and open the named pipe
    int ret = mkfifo(path, 0600);
    if (ret == -1) {
        int err = errno;
        if (err == ENOTSUP) {
            // Filesystem doesn't support named pipes, so try putting it in tmp instead
            // Hash collisions are okay here because they just result in doing
            // extra work, as opposed to correctness problems
            static NSString *tmpDir = NSTemporaryDirectory();
            path = [tmpDir stringByAppendingFormat:@"realm_%llu.note", (unsigned long long)[realm.path hash]].UTF8String;
            ret = mkfifo(path, 0600);
            err = errno;
        }
        // the fifo already existing isn't an error
        if (ret == -1 && err != EEXIST) {
            handleError(err, error);
            return;
        }
    }

    _notifyFd = open(path, O_RDWR);
    if (_notifyFd == -1) {
        handleError(errno, error);
        return;
    }

    // Make writing to the pipe return -1 when the pipe's buffer is full
    // rather than blocking until there's space available
    ret = fcntl(_notifyFd, F_SETFL, O_NONBLOCK);
    if (ret == -1) {
        handleError(errno, error);
        return;
    }

    // Create the anonymous pipe
    int pipeFd[2];
    ret = pipe(pipeFd);
    if (ret == -1) {
        handleError(errno, error);
        return;
    }

    _shutdownReadFd = pipeFd[0];
    _shutdownWriteFd = pipeFd[1];

    // Use the minimum allowed stack size, as we need very little in our listener
    // https://developer.apple.com/library/ios/documentation/Cocoa/Conceptual/Multithreading/CreatingThreads/CreatingThreads.html#//apple_ref/doc/uid/10000057i-CH15-SW7
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 16 * 1024);

    auto fn = [](void *self) -> void * {
        static_cast<RLMNotificationHelper *>(self)->listen();
        return nullptr;
    };
    ret = pthread_create(&_thread, &attr, fn, this);
    pthread_attr_destroy(&attr);
    if (ret != 0) {
        handleError(ret, error);
    }
}

void RLMNotificationHelper::listen() {
    pthread_setname_np("RLMRealm notification listener");

    // Create the runloop source
    CFRunLoopSourceContext ctx{};
    ctx.info = this;
    ctx.perform = [](void *info) {
        [static_cast<RLMNotificationHelper *>(info)->_realm notify];
    };

    CFRunLoopSourceRef signal = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &ctx);
    CFRunLoopAddSource(_runLoop, signal, kCFRunLoopDefaultMode);

    // Set up the kqueue
    // EVFILT_READ indicates that we care about data being available to read
    // on the given file descriptor.
    // EV_CLEAR makes it wait for the amount of data available to be read to
    // change rather than just returning when there is any data to read.
    struct kevent ke[2];
    EV_SET(&ke[0], _notifyFd, EVFILT_READ, EV_ADD | EV_CLEAR, 0, 0, 0);
    EV_SET(&ke[1], _shutdownReadFd, EVFILT_READ, EV_ADD | EV_CLEAR, 0, 0, 0);
    int ret = kevent(_kq, ke, 2, nullptr, 0, nullptr);
    assert(ret == 0);

    while (true) {
        struct kevent event;
        // Wait for data to become on either fd
        // Return code is number of bytes available or -1 on error
        ret = kevent(_kq, nullptr, 0, &event, 1, nullptr);
        assert(ret >= 0);
        if (ret == 0) {
            // Spurious wakeup; just wait again
            continue;
        }

        // Check which file descriptor had activity: if it's the shutdown
        // pipe, then someone called -stop; otherwise it's the named pipe
        // and someone committed a write transaction
        if (event.ident == (uint32_t)_shutdownReadFd) {
            CFRunLoopSourceInvalidate(signal);
            CFRelease(signal);
            CFRelease(_runLoop);
            return;
        }
        assert(event.ident == (uint32_t)_notifyFd);

        CFRunLoopSourceSignal(signal);
        // Signalling the source makes it run the next time the runloop gets
        // to it, but doesn't make the runloop start if it's currently idle
        // waiting for events
        CFRunLoopWakeUp(_runLoop);
    }
}

std::unique_ptr<realm::RealmDelegate> RLMCreateRealmDelegate(RLMRealm *realm, NSError **error) {
    std::unique_ptr<realm::RealmDelegate> delegate(new RLMNotificationHelper(realm, error));
    if (error && *error) {
        return nullptr;
    }
    return delegate;
}
