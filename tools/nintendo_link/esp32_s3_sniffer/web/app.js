// AeonDX GBA Link Bridge Web App
let tradeState = {
    connected: false,
    partnerName: "SWITCH 2",
    partnerLevel: 50,
    partnerHp: 100,
    playerMonIndex: 0,
    playerParty: [
        { name: "CHARIZARD", level: 50, hp: 153, maxHp: 153, species: 6, item: "Leftovers", moves: ["Flamethrower", "Wing Attack", "Slash", "Dragon Claw"] },
        { name: "PIKACHU", level: 48, hp: 110, maxHp: 110, species: 25, item: "Light Ball", moves: ["Thunderbolt", "Quick Attack", "Iron Tail", "Thunder Wave"] },
        { name: "BLASTOISE", level: 52, hp: 165, maxHp: 165, species: 9, item: "Mystic Water", moves: ["Surf", "Ice Beam", "Bite", "Hydro Pump"] },
        { name: "VENUSAUR", level: 50, hp: 155, maxHp: 155, species: 3, item: "Miracle Seed", moves: ["Solar Beam", "Sludge Bomb", "Sleep Powder", "Synthesis"] },
        { name: "SNORLAX", level: 55, hp: 220, maxHp: 220, species: 143, item: "Chesto Berry", moves: ["Body Slam", "Rest", "Shadow Ball", "Earthquake"] },
        { name: "DRATINI", level: 25, hp: 65, maxHp: 65, species: 147, item: "Dragon Scale", moves: ["Dragon Rage", "Thunder Wave", "Twister", "Slam"] }
    ],
    statusText: "Ready for GBA Wireless / Link trade.",
    sdMounted: true,
    sdCurrentSave: "/sdcard/saves/Pokemon_FireRed.sav",
    tradePhase: "IDLE" // IDLE, OFFERED, CONFIRMED, TRADING, COMPLETE
};

// Initialize UI
document.addEventListener("DOMContentLoaded", () => {
    updateUI();
    fetchStatus();
    setInterval(fetchStatus, 2000);
});

function typeDialogue(text) {
    const el = document.getElementById("dialogue-text");
    if (!el) return;
    el.innerText = text;
}

function updateUI() {
    const activeMon = tradeState.playerParty[tradeState.playerMonIndex] || tradeState.playerParty[0];
    
    // Partner Mon UI
    const partnerNameEl = document.getElementById("partner-name");
    const partnerLvlEl = document.getElementById("partner-level");
    const partnerHpFillEl = document.getElementById("partner-hp-fill");
    if (partnerNameEl) partnerNameEl.innerText = tradeState.partnerName;
    if (partnerLvlEl) partnerLvlEl.innerText = `Lv. ${tradeState.partnerLevel}`;
    if (partnerHpFillEl) partnerHpFillEl.style.width = `${tradeState.partnerHp}%`;

    // Player Mon UI
    const playerHpTextEl = document.getElementById("player-hp-text");
    if (playerHpTextEl && activeMon) {
        playerHpTextEl.innerText = `${activeMon.hp} / ${activeMon.maxHp}`;
    }

    // Secondary sub-mon cards
    const sub1 = document.getElementById("submon-1-name");
    const sub2 = document.getElementById("submon-2-name");
    const sub3 = document.getElementById("submon-3-name");
    if (sub1 && tradeState.playerParty[1]) sub1.innerText = tradeState.playerParty[1].name;
    if (sub2 && tradeState.playerParty[2]) sub2.innerText = tradeState.playerParty[2].name;
    if (sub3 && tradeState.playerParty[3]) sub3.innerText = tradeState.playerParty[3].name;

    // SD Card status
    const sdBadge = document.getElementById("sd-status-badge");
    const sdFile = document.getElementById("sd-current-file");
    if (sdBadge) {
        sdBadge.innerText = tradeState.sdMounted ? "MOUNTED" : "NO CARD";
        sdBadge.className = `sd-badge ${tradeState.sdMounted ? "badge-active" : "badge-idle"}`;
    }
    if (sdFile) {
        sdFile.innerText = tradeState.sdCurrentSave;
    }
}

// REST API calls
async function fetchStatus() {
    try {
        const res = await fetch("/api/status");
        if (res.ok) {
            const data = await res.json();
            tradeState.connected = data.connected;
            tradeState.partnerName = data.partner_name || tradeState.partnerName;
            tradeState.partnerLevel = data.partner_level || tradeState.partnerLevel;
            tradeState.sdMounted = data.sd_mounted;
            tradeState.sdCurrentSave = data.sd_save || tradeState.sdCurrentSave;
            tradeState.tradePhase = data.trade_phase || tradeState.tradePhase;
            updateUI();
        }
    } catch (e) {
        // Fallback or running in local dev / mock mode
    }
}

async function fetchParty() {
    try {
        const res = await fetch("/api/party");
        if (res.ok) {
            const data = await res.json();
            if (data.party && data.party.length > 0) {
                tradeState.playerParty = data.party;
                updateUI();
            }
        }
    } catch (e) {
        console.warn("Could not fetch party:", e);
    }
}

// 4 Main Actions
async function onFightClick() {
    const activeMon = tradeState.playerParty[tradeState.playerMonIndex];
    typeDialogue(`Offered ${activeMon.name} (Lv. ${activeMon.level}) for trade!`);
    
    try {
        const res = await fetch("/api/trade/offer", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ slot: tradeState.playerMonIndex })
        });
        if (res.ok) {
            const data = await res.json();
            typeDialogue(data.message || `Offered ${activeMon.name}! Waiting for partner...`);
            tradeState.tradePhase = "OFFERED";
        }
    } catch (e) {
        typeDialogue(`Offered ${activeMon.name}! Waiting for partner confirmation.`);
    }
}

function onBagClick() {
    openModal();
    renderPartyGrid();
    fetchSavesList();
}

async function onItemClick() {
    const activeMon = tradeState.playerParty[tradeState.playerMonIndex];
    const details = `[${activeMon.name}] Lv.${activeMon.level} | Item: ${activeMon.item || "None"} | Moves: ${activeMon.moves.join(", ")}`;
    typeDialogue(details);
}

async function onRunClick() {
    typeDialogue("Cancelling trade proposal...");
    try {
        const res = await fetch("/api/trade/cancel", { method: "POST" });
        if (res.ok) {
            const data = await res.json();
            typeDialogue(data.message || "Trade cancelled.");
            tradeState.tradePhase = "IDLE";
        }
    } catch (e) {
        typeDialogue("Trade proposal cancelled.");
        tradeState.tradePhase = "IDLE";
    }
}

// Modal Handlers
function openModal() {
    const modal = document.getElementById("party-modal");
    if (modal) modal.style.display = "flex";
}

function closeModal() {
    const modal = document.getElementById("party-modal");
    if (modal) modal.style.display = "none";
}

function renderPartyGrid() {
    const grid = document.getElementById("party-grid");
    if (!grid) return;
    grid.innerHTML = "";

    tradeState.playerParty.forEach((mon, idx) => {
        const card = document.createElement("div");
        card.className = `party-slot ${idx === tradeState.playerMonIndex ? "selected" : ""}`;
        card.onclick = () => selectPartySlot(idx);
        card.innerHTML = `
            <div class="slot-icon">#${idx + 1}</div>
            <div class="slot-details">
                <div class="slot-name">${mon.name}</div>
                <div class="slot-sub">Lv. ${mon.level} | HP ${mon.hp}/${mon.maxHp}</div>
            </div>
        `;
        grid.appendChild(card);
    });
}

function selectPartySlot(idx) {
    tradeState.playerMonIndex = idx;
    const mon = tradeState.playerParty[idx];
    typeDialogue(`Selected ${mon.name} (Lv. ${mon.level}) from SD party.`);
    renderPartyGrid();
    updateUI();
    closeModal();
}

async function fetchSavesList() {
    try {
        const res = await fetch("/api/sd/saves");
        if (res.ok) {
            const data = await res.json();
            const select = document.getElementById("save-file-select");
            if (select && data.saves) {
                select.innerHTML = "";
                data.saves.forEach(save => {
                    const opt = document.createElement("option");
                    opt.value = save.name;
                    opt.innerText = `${save.name} (${Math.round(save.size / 1024)} KB)`;
                    if (save.name === tradeState.sdCurrentSave) opt.selected = true;
                    select.appendChild(opt);
                });
            }
        }
    } catch (e) {
        // Fallback default options already in HTML
    }
}

async function onSaveFileSelected(filename) {
    typeDialogue(`Loading save file ${filename} from SD card...`);
    try {
        const res = await fetch("/api/sd/load", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ filename })
        });
        if (res.ok) {
            tradeState.sdCurrentSave = filename;
            await fetchParty();
            typeDialogue(`Loaded party from ${filename}!`);
        }
    } catch (e) {
        tradeState.sdCurrentSave = filename;
        typeDialogue(`Loaded party from ${filename}.`);
    }
}
