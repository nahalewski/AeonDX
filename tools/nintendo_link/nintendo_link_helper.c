#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <linux/if_packet.h>
#include <linux/if_ether.h>
#include <linux/netlink.h>
#include <linux/genetlink.h>
#include <linux/nl80211.h>
#include <net/if.h>
#include <arpa/inet.h>

#define GOOGLE_OUI 0x001A11

#define SUBCMD_SET_FREQUENCY      1
#define SUBCMD_SET_FILTER         2
#define SUBCMD_SET_FIXED_TX_RATE  3
#define SUBCMD_SET_REG            4

#ifndef NLA_HDRLEN
#define NLA_HDRLEN ((int)NLA_ALIGN(sizeof(struct nlattr)))
#endif
#ifndef NLA_DATA
#define NLA_DATA(nla) ((void *)((char *)(nla) + NLA_HDRLEN))
#endif
#ifndef NLA_OK
#define NLA_OK(nla, len) ((len) >= (int)sizeof(struct nlattr) && \
                          (nla)->nla_len >= sizeof(struct nlattr) && \
                          (nla)->nla_len <= (len))
#endif
#ifndef NLA_NEXT
#define NLA_NEXT(nla, attrlen) \
    ((attrlen) -= NLA_ALIGN((nla)->nla_len), \
     (struct nlattr *)(((char *)(nla)) + NLA_ALIGN((nla)->nla_len)))
#endif

static volatile sig_atomic_t g_running = 1;
static char g_ifname[32] = "wonder0";
static int g_need_cleanup = 0;
static int g_created_interface = 0;

struct payload {
    int len;
    char data[2048];
};

static void add_attr(struct payload *p, int type, int len, const void *val) {
    int alen = NLA_HDRLEN + len;
    int aligned = NLA_ALIGN(alen);
    struct nlattr *nla = (struct nlattr *)(p->data + p->len);
    nla->nla_type = type;
    nla->nla_len = alen;
    if (len && val) memcpy((char *)nla + NLA_HDRLEN, val, len);
    memset((char *)nla + alen, 0, aligned - alen);
    p->len += aligned;
}

static void add_u32(struct payload *p, int type, uint32_t v) { add_attr(p, type, 4, &v); }
static void add_u8(struct payload *p, int type, uint8_t v) { add_attr(p, type, 1, &v); }
static void add_u16(struct payload *p, int type, uint16_t v) { add_attr(p, type, 2, &v); }

static struct nlattr *add_nest(struct payload *p, int type) {
    struct nlattr *nla = (struct nlattr *)(p->data + p->len);
    nla->nla_type = type;
    nla->nla_len = NLA_HDRLEN;
    p->len += NLA_HDRLEN;
    return nla;
}

static void end_nest(struct payload *p, struct nlattr *nla) {
    nla->nla_len = (p->data + p->len) - (char *)nla;
    int aligned = NLA_ALIGN(nla->nla_len);
    int pad = aligned - nla->nla_len;
    if (pad > 0) {
        memset(p->data + p->len, 0, pad);
        p->len += pad;
    }
}

static int get_family_id(int fd, const char *name) {
    char req_buf[1024];
    struct nlmsghdr *nlh = (struct nlmsghdr *)req_buf;
    struct genlmsghdr *gh = (struct genlmsghdr *)NLMSG_DATA(nlh);

    nlh->nlmsg_len = NLMSG_LENGTH(GENL_HDRLEN);
    nlh->nlmsg_type = GENL_ID_CTRL;
    nlh->nlmsg_flags = NLM_F_REQUEST;
    nlh->nlmsg_seq = 100;
    gh->cmd = CTRL_CMD_GETFAMILY;
    gh->version = 1;

    struct payload p = {0};
    add_attr(&p, CTRL_ATTR_FAMILY_NAME, strlen(name) + 1, name);
    memcpy((char *)gh + GENL_HDRLEN, p.data, p.len);
    nlh->nlmsg_len += p.len;

    if (send(fd, nlh, nlh->nlmsg_len, 0) < 0) return -1;

    char buf[4096];
    int len = recv(fd, buf, sizeof(buf), 0);
    if (len <= 0) return -1;

    nlh = (struct nlmsghdr *)buf;
    while (NLMSG_OK(nlh, len)) {
        if (nlh->nlmsg_type == GENL_ID_CTRL) {
            gh = (struct genlmsghdr *)NLMSG_DATA(nlh);
            struct nlattr *a = (struct nlattr *)((char *)gh + GENL_HDRLEN);
            int rem = nlh->nlmsg_len - NLMSG_LENGTH(GENL_HDRLEN);
            while (rem >= (int)sizeof(struct nlattr) && a->nla_len >= sizeof(struct nlattr) && a->nla_len <= rem) {
                if (a->nla_type == CTRL_ATTR_FAMILY_ID) {
                    return *(uint16_t *)((char *)a + NLA_HDRLEN);
                }
                int alen = NLA_ALIGN(a->nla_len);
                rem -= alen;
                a = (struct nlattr *)((char *)a + alen);
            }
        }
        nlh = NLMSG_NEXT(nlh, len);
    }
    return -1;
}

static int get_wiphy_id(int fd, int genl_id, const char *name, uint32_t *wiphy_id) {
    char req_buf[1024] = {0};
    struct nlmsghdr *nlh = (struct nlmsghdr *)req_buf;
    struct genlmsghdr *gh = (struct genlmsghdr *)NLMSG_DATA(nlh);

    nlh->nlmsg_len = NLMSG_LENGTH(GENL_HDRLEN);
    nlh->nlmsg_type = genl_id;
    nlh->nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;
    nlh->nlmsg_seq = 150;
    gh->cmd = NL80211_CMD_GET_WIPHY;
    gh->version = 1;

    if (send(fd, nlh, nlh->nlmsg_len, 0) < 0) return -1;

    char buf[8192];
    for (;;) {
        int len = recv(fd, buf, sizeof(buf), 0);
        if (len <= 0) return -1;

        nlh = (struct nlmsghdr *)buf;
        while (NLMSG_OK(nlh, len)) {
            if (nlh->nlmsg_type == NLMSG_DONE) return -1;
            if (nlh->nlmsg_type == NLMSG_ERROR) {
                struct nlmsgerr *err = (struct nlmsgerr *)NLMSG_DATA(nlh);
                return err->error;
            }
            if (nlh->nlmsg_type == genl_id) {
                gh = (struct genlmsghdr *)NLMSG_DATA(nlh);
                int rem = nlh->nlmsg_len - NLMSG_LENGTH(GENL_HDRLEN);
                struct nlattr *attr = (struct nlattr *)((char *)gh + GENL_HDRLEN);
                const char *wiphy_name = NULL;
                uint32_t found_id = 0;
                int has_id = 0;

                while (NLA_OK(attr, rem)) {
                    int value_len = attr->nla_len - NLA_HDRLEN;
                    if (attr->nla_type == NL80211_ATTR_WIPHY_NAME && value_len > 0) {
                        wiphy_name = (const char *)NLA_DATA(attr);
                    } else if (attr->nla_type == NL80211_ATTR_WIPHY && value_len >= (int)sizeof(found_id)) {
                        memcpy(&found_id, NLA_DATA(attr), sizeof(found_id));
                        has_id = 1;
                    }
                    attr = NLA_NEXT(attr, rem);
                }
                if (wiphy_name && has_id && strcmp(wiphy_name, name) == 0) {
                    *wiphy_id = found_id;
                    return 0;
                }
            }
            nlh = NLMSG_NEXT(nlh, len);
        }
    }
}

static int send_vendor(int fd, int genl_id, uint32_t ifidx, uint32_t subcmd,
                       const void *payload, int plen) {
    char req_buf[4096];
    struct nlmsghdr *nlh = (struct nlmsghdr *)req_buf;
    struct genlmsghdr *gh = (struct genlmsghdr *)NLMSG_DATA(nlh);

    nlh->nlmsg_len = NLMSG_LENGTH(GENL_HDRLEN);
    nlh->nlmsg_type = genl_id;
    nlh->nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK;
    nlh->nlmsg_seq = 200 + subcmd;
    gh->cmd = NL80211_CMD_VENDOR;
    gh->version = 1;

    struct payload top = {0};
    add_u32(&top, NL80211_ATTR_IFINDEX, ifidx);
    add_u32(&top, NL80211_ATTR_VENDOR_ID, GOOGLE_OUI);
    add_u32(&top, NL80211_ATTR_VENDOR_SUBCMD, subcmd);
    if (payload && plen > 0) add_attr(&top, NL80211_ATTR_VENDOR_DATA, plen, payload);
    memcpy((char *)gh + GENL_HDRLEN, top.data, top.len);
    nlh->nlmsg_len += top.len;

    if (send(fd, nlh, nlh->nlmsg_len, 0) < 0) return -1;

    char buf[4096];
    int len = recv(fd, buf, sizeof(buf), 0);
    if (len < 0) return -1;

    nlh = (struct nlmsghdr *)buf;
    while (NLMSG_OK(nlh, len)) {
        if (nlh->nlmsg_type == NLMSG_ERROR) {
            struct nlmsgerr *err = (struct nlmsgerr *)NLMSG_DATA(nlh);
            return err->error;
        }
        nlh = NLMSG_NEXT(nlh, len);
    }
    return 0;
}

static int configure_wonder_radio(int fd, int fid, uint32_t ifidx, uint32_t freq) {
    struct payload frequency = {0};
    add_u32(&frequency, 1, freq);
    add_u16(&frequency, 2, 20);
    if (send_vendor(fd, fid, ifidx, SUBCMD_SET_FREQUENCY,
                    frequency.data, frequency.len) != 0) return -1;

    struct payload fixed_rate = {0};
    add_u32(&fixed_rate, 1, 1);
    add_u16(&fixed_rate, 2, 0);
    add_u32(&fixed_rate, 3, 0);
    add_u8(&fixed_rate, 4, 1);
    add_u8(&fixed_rate, 5, 0);
    if (send_vendor(fd, fid, ifidx, SUBCMD_SET_FIXED_TX_RATE,
                    fixed_rate.data, fixed_rate.len) != 0) return -2;

    struct payload filter = {0};
    add_u32(&filter, 1, 0);
    struct nlattr *nest = add_nest(&filter, 2);
    add_u8(&filter, 1, 0);
    end_nest(&filter, nest);
    if (send_vendor(fd, fid, ifidx, SUBCMD_SET_FILTER,
                    filter.data, filter.len) != 0) return -3;

    struct payload country = {0};
    add_attr(&country, 1, 3, "US");
    if (send_vendor(fd, fid, ifidx, SUBCMD_SET_REG,
                    country.data, country.len) != 0) return -4;

    return 0;
}

static int nl_create_interface(int fd, int genl_id, uint32_t wiphy, const char *name, int mode) {
    char req_buf[1024];
    struct nlmsghdr *nlh = (struct nlmsghdr *)req_buf;
    struct genlmsghdr *gh = (struct genlmsghdr *)NLMSG_DATA(nlh);

    nlh->nlmsg_len = NLMSG_LENGTH(GENL_HDRLEN);
    nlh->nlmsg_type = genl_id;
    nlh->nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK;
    nlh->nlmsg_seq = 300;
    gh->cmd = NL80211_CMD_NEW_INTERFACE;
    gh->version = 1;

    struct payload p = {0};
    add_u32(&p, NL80211_ATTR_WIPHY, wiphy);
    add_attr(&p, NL80211_ATTR_IFNAME, strlen(name) + 1, name);
    add_u32(&p, NL80211_ATTR_IFTYPE, mode);

    memcpy((char *)gh + GENL_HDRLEN, p.data, p.len);
    nlh->nlmsg_len += p.len;

    if (send(fd, nlh, nlh->nlmsg_len, 0) < 0) return -1;

    char buf[4096];
    int len = recv(fd, buf, sizeof(buf), 0);
    if (len < 0) return -1;

    nlh = (struct nlmsghdr *)buf;
    while (NLMSG_OK(nlh, len)) {
        if (nlh->nlmsg_type == NLMSG_ERROR) {
            struct nlmsgerr *err = (struct nlmsgerr *)NLMSG_DATA(nlh);
            return err->error;
        }
        nlh = NLMSG_NEXT(nlh, len);
    }
    return 0;
}

static int nl_delete_interface(int fd, int genl_id, uint32_t ifidx) {
    char req_buf[1024];
    struct nlmsghdr *nlh = (struct nlmsghdr *)req_buf;
    struct genlmsghdr *gh = (struct genlmsghdr *)NLMSG_DATA(nlh);

    nlh->nlmsg_len = NLMSG_LENGTH(GENL_HDRLEN);
    nlh->nlmsg_type = genl_id;
    nlh->nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK;
    nlh->nlmsg_seq = 301;
    gh->cmd = NL80211_CMD_DEL_INTERFACE;
    gh->version = 1;

    struct payload p = {0};
    add_u32(&p, NL80211_ATTR_IFINDEX, ifidx);

    memcpy((char *)gh + GENL_HDRLEN, p.data, p.len);
    nlh->nlmsg_len += p.len;

    if (send(fd, nlh, nlh->nlmsg_len, 0) < 0) return -1;

    char buf[4096];
    int len = recv(fd, buf, sizeof(buf), 0);
    if (len < 0) return -1;

    nlh = (struct nlmsghdr *)buf;
    while (NLMSG_OK(nlh, len)) {
        if (nlh->nlmsg_type == NLMSG_ERROR) {
            struct nlmsgerr *err = (struct nlmsgerr *)NLMSG_DATA(nlh);
            return err->error;
        }
        nlh = NLMSG_NEXT(nlh, len);
    }
    return 0;
}

static int set_link_state(const char *name, int up) {
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return -1;
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);
    if (ioctl(s, SIOCGIFFLAGS, &ifr) < 0) { close(s); return -1; }
    if (up) ifr.ifr_flags |= IFF_UP;
    else ifr.ifr_flags &= ~IFF_UP;
    int r = ioctl(s, SIOCSIFFLAGS, &ifr);
    close(s);
    return r;
}

static void restore_system_wifi(void) {
    if (!g_need_cleanup) return;
    printf("\n[teardown] Restoring Android network and cleaning up interfaces...\n");
    set_link_state("wondertap0", 0);
    set_link_state(g_ifname, 0);

    if (g_created_interface) {
        int fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_GENERIC);
        if (fd >= 0) {
            int fid = get_family_id(fd, "nl80211");
            if (fid > 0) {
                uint32_t ifidx = if_nametoindex(g_ifname);
                if (ifidx > 0) nl_delete_interface(fd, fid, ifidx);
            }
            close(fd);
        }
    }

    // Restore Wi-Fi service
    system("cmd wifi set-wifi-enabled disabled >/dev/null 2>&1; sleep 1; cmd wifi set-wifi-enabled enabled >/dev/null 2>&1");
    g_need_cleanup = 0;
    printf("[teardown] Normal Wi-Fi restored.\n");
}

static void sig_handler(int sig) {
    (void)sig;
    g_running = 0;
}

static int run_listen_test(int seconds_per_channel) {
    int nl_fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_GENERIC);
    if (nl_fd < 0) { perror("nl socket"); return 1; }

    struct sockaddr_nl sa = { .nl_family = AF_NETLINK };
    bind(nl_fd, (struct sockaddr *)&sa, sizeof(sa));

    int fid = get_family_id(nl_fd, "nl80211");
    if (fid <= 0) {
        fprintf(stderr, "Failed to resolve nl80211\n");
        close(nl_fd);
        return 1;
    }

    uint32_t ifidx = if_nametoindex(g_ifname);
    if (ifidx == 0) {
        uint32_t wiphy_id = 0;
        int wiphy_ret = get_wiphy_id(nl_fd, fid, "wonder", &wiphy_id);
        if (wiphy_ret != 0) {
            fprintf(stderr, "Could not find nl80211 phy 'wonder': %s\n",
                    wiphy_ret < 0 ? strerror(-wiphy_ret) : "lookup failed");
            close(nl_fd);
            return 1;
        }
        printf("[init] Creating monitor interface %s on phy wonder (wiphy %u)...\n",
               g_ifname, wiphy_id);
        int create_ret = nl_create_interface(nl_fd, fid, wiphy_id, g_ifname,
                                             NL80211_IFTYPE_MONITOR);
        if (create_ret != 0) {
            fprintf(stderr, "Could not create interface %s on phy wonder: %s\n",
                    g_ifname, create_ret < 0 ? strerror(-create_ret) : "request failed");
            close(nl_fd);
            return 1;
        }
        ifidx = if_nametoindex(g_ifname);
        if (ifidx == 0) {
            fprintf(stderr, "Could not create interface %s\n", g_ifname);
            close(nl_fd);
            return 1;
        }
        g_created_interface = 1;
    }
    g_need_cleanup = 1;

    printf("[init] Pausing Android Wi-Fi to free the shared monitor radio...\n");
    if (system("cmd wifi set-wifi-enabled disabled >/dev/null 2>&1 && sleep 1") != 0) {
        fprintf(stderr, "Could not pause Android Wi-Fi for channel hopping\n");
        restore_system_wifi();
        close(nl_fd);
        return 1;
    }

    if (set_link_state("wondertap0", 1) < 0) {
        perror("could not activate wondertap0 RX provider");
        restore_system_wifi();
        close(nl_fd);
        return 1;
    }

    uint32_t channels[] = {
        2412, 2437, 2462,
        5180, 5200, 5220, 5240,
        5745, 5765, 5785, 5805, 5825
    };
    int ch_nums[] = { 1, 6, 11, 36, 40, 44, 48, 149, 153, 157, 161, 165 };
    const int channel_count = sizeof(channels) / sizeof(channels[0]);
    int total_nintendo_frames = 0;

    int sock = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
    if (sock < 0) { perror("packet socket"); close(nl_fd); return 1; }

    struct sockaddr_ll sll;
    memset(&sll, 0, sizeof(sll));
    sll.sll_family = AF_PACKET;
    sll.sll_ifindex = ifidx;
    sll.sll_protocol = htons(ETH_P_ALL);
    if (bind(sock, (struct sockaddr *)&sll, sizeof(sll)) < 0) {
        perror("packet bind");
        close(sock); close(nl_fd);
        return 1;
    }

    // Set nonblocking timeout
    struct timeval tv = { .tv_sec = 0, .tv_usec = 100000 };
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    printf("========================================================\n");
    printf("  Nintendo Link Bridge - Test 2: Room Listener\n");
    printf("  Listening for Switch LDN Action Frames (OUI 00:22:aa)\n");
    printf("========================================================\n");

    for (int c = 0; c < channel_count && g_running; c++) {
        uint32_t freq = channels[c];
        int ch = ch_nums[c];
        printf("\n-- Channel %d (%u MHz) --\n", ch, freq);

        set_link_state(g_ifname, 0);
        int cfg_ret = configure_wonder_radio(nl_fd, fid, ifidx, freq);
        if (cfg_ret != 0) {
            printf("   Failed to configure wonder radio: error %d\n", cfg_ret);
            continue;
        }

        if (set_link_state(g_ifname, 1) < 0) {
            printf("   Failed to bring %s up\n", g_ifname);
            continue;
        }

        time_t start = time(NULL);
        int ch_frames = 0;
        int nintendo_frames = 0;

        while (g_running && (time(NULL) - start < seconds_per_channel)) {
            unsigned char buf[4096];
            int n = recv(sock, buf, sizeof(buf), 0);
            if (n <= 0) continue;
            ch_frames++;

            // Look for Nintendo OUI: 00:22:aa
            for (int i = 0; i < n - 3; i++) {
                if (buf[i] == 0x00 && buf[i+1] == 0x22 && buf[i+2] == 0xaa) {
                    nintendo_frames++;
                    total_nintendo_frames++;
                    printf("   >>> [MATCH] Nintendo frame detected! (len=%d)\n", n);
                    // Print surrounding bytes
                    printf("       Payload: ");
                    int dump_len = (n - i > 32) ? 32 : (n - i);
                    for (int j = 0; j < dump_len; j++) printf("%02x ", buf[i+j]);
                    printf("\n");
                    break;
                }
            }
        }

        printf("   Packets captured: %d | Nintendo-OUI frames: %d\n", ch_frames, nintendo_frames);
    }

    close(sock);
    close(nl_fd);

    printf("\n========================================================\n");
    printf("Total Nintendo-OUI frames detected: %d\n", total_nintendo_frames);
    if (total_nintendo_frames > 0) {
        printf("PASS: The phone hears the Switch LDN room on the wonder radio!\n");
    } else {
        printf("No Nintendo frames detected.\n");
        printf("Check that your Switch is in a local-wireless screen (e.g. Union Room) close by.\n");
    }
    printf("========================================================\n");

    return (total_nintendo_frames > 0) ? 0 : 2;
}

int main(int argc, char **argv) {
    signal(SIGINT, sig_handler);
    signal(SIGTERM, sig_handler);
    signal(SIGHUP, sig_handler);

    if (argc > 1 && strcmp(argv[1], "restore") == 0) {
        g_need_cleanup = 1;
        restore_system_wifi();
        return 0;
    }

    int secs = (argc > 1) ? atoi(argv[1]) : 10;
    int ret = run_listen_test(secs);

    restore_system_wifi();
    return ret;
}
