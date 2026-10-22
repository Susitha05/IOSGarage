// Firebase Cloud Functions (2nd gen). `firebase init functions`, replace index.js, `firebase deploy --only functions`.
// Sends FCM pushes (delivered through APNs) for booking, tow and new-job events.
const { onDocumentUpdated, onDocumentCreated } = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");
admin.initializeApp();

async function pushToUser(uid, title, body) {
  const snap = await admin.firestore().collection("users").doc(uid).get();
  const token = snap.get("fcmToken");
  if (token) await admin.messaging().send({ token, notification: { title, body }, apns: { payload: { aps: { sound: "default" } } } });
}

exports.appointmentStatus = onDocumentUpdated("appointments/{id}", async (e) => {
  const a = e.data.after.data(), b = e.data.before.data();
  if (a.status !== b.status) await pushToUser(a.customerId, "Booking update", `${a.service} at ${a.garageName}: ${a.status}`);
});

exports.towStatus = onDocumentUpdated("towRequests/{id}", async (e) => {
  const a = e.data.after.data(), b = e.data.before.data();
  if (a.status !== b.status) await pushToUser(a.customerId, "Tow update", `Status: ${a.status}`);
});

exports.newTow = onDocumentCreated("towRequests/{id}", async (e) => {
  await admin.messaging().send({ topic: "drivers", notification: { title: "New tow request", body: e.data.get("customerName") + " needs help" } });
});

exports.newAppointment = onDocumentCreated("appointments/{id}", async (e) => {
  await pushToUser(e.data.get("garageId"), "New booking", `${e.data.get("customerName")} – ${e.data.get("service")}`);
});
