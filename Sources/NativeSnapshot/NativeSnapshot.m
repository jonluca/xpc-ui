#import "NativeSnapshot.h"

#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <libproc.h>
#import <mach/mach.h>
#import <netinet/in.h>
#import <sys/proc_info.h>
#import <sys/socket.h>

static NSString *XPCUIIPAddress(const struct in_sockinfo *info, BOOL local) {
    char buffer[INET6_ADDRSTRLEN] = {0};
    const void *address = NULL;
    if (info->insi_vflag & INI_IPV4) {
        address = local ? &info->insi_laddr.ina_46.i46a_addr4 : &info->insi_faddr.ina_46.i46a_addr4;
        inet_ntop(AF_INET, address, buffer, sizeof(buffer));
    } else if (info->insi_vflag & INI_IPV6) {
        address = local ? &info->insi_laddr.ina_6 : &info->insi_faddr.ina_6;
        inet_ntop(AF_INET6, address, buffer, sizeof(buffer));
    }
    if (!address || buffer[0] == '\0') {
        return nil;
    }
    int port = ntohs(local ? info->insi_lport : info->insi_fport);
    return [NSString stringWithFormat:@"%s:%d", buffer, port];
}

static const struct in_sockinfo *XPCUIInternetInfo(const struct socket_info *info) {
    if (info->soi_kind == SOCKINFO_TCP) {
        return &info->soi_proto.pri_tcp.tcpsi_ini;
    }
    if (info->soi_kind == SOCKINFO_IN) {
        return &info->soi_proto.pri_in;
    }
    return NULL;
}

static NSDictionary *XPCUISocketDictionary(int fd, const struct socket_fdinfo *socketInfo) {
    const struct socket_info *info = &socketInfo->psi;
    NSMutableDictionary *result = [@{
        @"fd": @(fd),
        @"family": @(info->soi_family),
        @"type": @(info->soi_type),
        @"protocolNumber": @(info->soi_protocol),
    } mutableCopy];
    const struct in_sockinfo *internetInfo = XPCUIInternetInfo(info);
    if (internetInfo) {
        result[@"localEndpoint"] = XPCUIIPAddress(internetInfo, YES);
        result[@"remoteEndpoint"] = XPCUIIPAddress(internetInfo, NO);
    } else if (info->soi_kind == SOCKINFO_UN) {
        const char *localPath = info->soi_proto.pri_un.unsi_addr.ua_sun.sun_path;
        const char *remotePath = info->soi_proto.pri_un.unsi_caddr.ua_sun.sun_path;
        if (localPath[0] != '\0') {
            result[@"localEndpoint"] = [NSString stringWithUTF8String:localPath];
        }
        if (remotePath[0] != '\0') {
            result[@"remoteEndpoint"] = [NSString stringWithUTF8String:remotePath];
        }
    }
    return result;
}

static NSArray *XPCUIOpenFiles(pid_t pid, NSMutableArray *sockets) {
    int size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (size <= 0) {
        return @[];
    }
    struct proc_fdinfo *descriptors = calloc(1, (size_t)size);
    int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, descriptors, size);
    if (bytes <= 0) {
        free(descriptors);
        return @[];
    }
    NSMutableArray *files = [NSMutableArray array];
    int count = bytes / (int)sizeof(struct proc_fdinfo);
    for (int index = 0; index < count; index++) {
        struct proc_fdinfo descriptor = descriptors[index];
        if (descriptor.proc_fdtype == PROX_FDTYPE_VNODE) {
            struct vnode_fdinfowithpath info = {0};
            int result = proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, sizeof(info));
            if (result == sizeof(info) && info.pvip.vip_path[0] != '\0') {
                BOOL isDirectory = (info.pfi.fi_status & S_IFMT) == S_IFDIR;
                [files addObject:@{
                    @"fd": @(descriptor.proc_fd),
                    @"path": [NSString stringWithUTF8String:info.pvip.vip_path],
                    @"isDirectory": @(isDirectory),
                }];
            }
        } else if (descriptor.proc_fdtype == PROX_FDTYPE_SOCKET) {
            struct socket_fdinfo info = {0};
            int result = proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, sizeof(info));
            if (result == sizeof(info)) {
                [sockets addObject:XPCUISocketDictionary(descriptor.proc_fd, &info)];
            }
        }
    }
    free(descriptors);
    return files;
}

static NSArray *XPCUIMachPorts(pid_t pid, NSString **error) {
    mach_port_t task = MACH_PORT_NULL;
    kern_return_t taskResult = task_for_pid(mach_task_self(), pid, &task);
    if (taskResult != KERN_SUCCESS) {
        *error = [NSString stringWithFormat:@"Mach namespace unavailable: %s", mach_error_string(taskResult)];
        return @[];
    }
    mach_port_name_array_t names = NULL;
    mach_port_type_array_t types = NULL;
    mach_msg_type_number_t nameCount = 0;
    mach_msg_type_number_t typeCount = 0;
    kern_return_t result = mach_port_names(task, &names, &nameCount, &types, &typeCount);
    mach_port_deallocate(mach_task_self(), task);
    if (result != KERN_SUCCESS) {
        *error = [NSString stringWithFormat:@"Unable to enumerate Mach ports: %s", mach_error_string(result)];
        return @[];
    }
    NSMutableArray *ports = [NSMutableArray arrayWithCapacity:nameCount];
    mach_msg_type_number_t count = MIN(nameCount, typeCount);
    for (mach_msg_type_number_t index = 0; index < count; index++) {
        [ports addObject:@{@"name": @(names[index]), @"typeBits": @(types[index])}];
    }
    vm_deallocate(mach_task_self(), (vm_address_t)names, nameCount * sizeof(mach_port_name_t));
    vm_deallocate(mach_task_self(), (vm_address_t)types, typeCount * sizeof(mach_port_type_t));
    return ports;
}

char *XPCUICopyProcessSnapshotJSON(pid_t pid) {
    @autoreleasepool {
        NSMutableArray *sockets = [NSMutableArray array];
        NSArray *files = XPCUIOpenFiles(pid, sockets);
        NSString *error = nil;
        NSArray *machPorts = XPCUIMachPorts(pid, &error);
        NSMutableDictionary *snapshot = [@{
            @"pid": @(pid),
            @"files": files,
            @"sockets": sockets,
            @"machPorts": machPorts,
        } mutableCopy];
        if (error) {
            snapshot[@"error"] = error;
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
        char *result = calloc(1, data.length + 1);
        memcpy(result, data.bytes, data.length);
        return result;
    }
}

void XPCUIFreeCString(char *string) {
    free(string);
}
