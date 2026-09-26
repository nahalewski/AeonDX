#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <linux/netlink.h>
#include <linux/genetlink.h>
#include <linux/nl80211.h>
#include <net/if.h>

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

static void add_u8(struct payload *p, int type, uint8_t v) { add_attr(p, type, 1, &v); }
static void add_u16(struct payload *p, int type, uint16_t v) { add_attr(p, type, 2, &v); }
static void add_u32(struct payload *p, int type, uint32_t v) { add_attr(p, type, 4, &v); }

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
    if (payload && plen > 0) {
        add_attr(&top, NL80211_ATTR_VENDOR_DATA, plen, payload);
    }

    memcpy((char *)gh + GENL_HDRLEN, top.data, top.len);
    nlh->nlmsg_len += top.len;

    if (send(fd, nlh, nlh->nlmsg_len, 0) < 0) {
        perror("send");
        return -1;
    }

    char buf[4096];
    int len = recv(fd, buf, sizeof(buf), 0);
    if (len < 0) {
        perror("recv");
        return -1;
    }

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

int main(int argc, char **argv) {
    const char *ifname = (argc > 1) ? argv[1] : "wonder0";
    uint32_t ifidx = if_nametoindex(ifname);
    if (!ifidx) {
        fprintf(stderr, "Interface %s not found\n", ifname);
        return 1;
    }
    printf("Using interface %s (ifindex %u)\n", ifname, ifidx);

    int fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_GENERIC);
    if (fd < 0) { perror("socket"); return 1; }

    struct sockaddr_nl sa = { .nl_family = AF_NETLINK };
    if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        perror("bind"); close(fd); return 1;
    }

    int fid = get_family_id(fd, "nl80211");
    if (fid <= 0) {
        fprintf(stderr, "Failed to resolve nl80211 family\n");
        close(fd); return 1;
    }
    printf("Resolved nl80211 family ID: %d\n", fid);

    uint32_t freq = (argc > 2) ? atoi(argv[2]) : 2412;

    // 1. Frequency
    printf("== 1. Sending SET_FREQUENCY (freq=%u, bw=20)...\n", freq);
    {
        struct payload p = {0};
        add_u32(&p, 1, freq);
        add_u16(&p, 2, 20);
        int r = send_vendor(fd, fid, ifidx, SUBCMD_SET_FREQUENCY, p.data, p.len);
        printf("   result: %d (%s)\n", r, r ? strerror(-r) : "OK");
    }

    // 2. Fixed TX Rate (HT, BW=0, GI=0, NSS=1, MCS=0)
    printf("== 2. Sending SET_FIXED_TX_RATE (pre=1, bw=0, gi=0, nss=1, mcs=0)...\n");
    {
        struct payload p = {0};
        add_u32(&p, 1, 1); // pre = 1 (HT)
        add_u16(&p, 2, 0); // bw = 0 (20MHz)
        add_u32(&p, 3, 0); // gi = 0
        add_u8(&p, 4, 1);  // nss = 1
        add_u8(&p, 5, 0);  // mcs = 0
        int r = send_vendor(fd, fid, ifidx, SUBCMD_SET_FIXED_TX_RATE, p.data, p.len);
        printf("   result: %d (%s)\n", r, r ? strerror(-r) : "OK");
    }

    // 3. Filter
    printf("== 3. Sending SET_FILTER (BSSID filter disabled)...\n");
    {
        struct payload p = {0};
        add_u32(&p, 1, 0); // FILTER_TYPE = 0 (BSSID)
        struct nlattr *nest = add_nest(&p, 2); // FILTER_PARAMS
        add_u8(&p, 1, 0); // ENABLED = 0
        end_nest(&p, nest);
        int r = send_vendor(fd, fid, ifidx, SUBCMD_SET_FILTER, p.data, p.len);
        printf("   result: %d (%s)\n", r, r ? strerror(-r) : "OK");
    }

    // 4. Country Code
    printf("== 4. Sending SET_REG (US)...\n");
    {
        struct payload p = {0};
        add_attr(&p, 1, 3, "US"); // Null-terminated "US\0" (3 bytes)
        int r = send_vendor(fd, fid, ifidx, SUBCMD_SET_REG, p.data, p.len);
        printf("   result: %d (%s)\n", r, r ? strerror(-r) : "OK");
    }

    close(fd);
    printf("== Finished sending cached settings!\n");
    return 0;
}
