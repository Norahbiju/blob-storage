require('dotenv').config();

const express = require('express');
const session = require('express-session');
const helmet = require('helmet');
const multer = require('multer');
const path = require('path');
const { v4: uuidv4 } = require('uuid');
const storage = require('./storage');

const app = express();
const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 10 * 1024 * 1024 }
});

app.set('trust proxy', 1);
app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, 'views'));

app.use(
  helmet({
    contentSecurityPolicy: false
  })
);
app.use(express.urlencoded({ extended: true }));
app.use(express.static(path.join(__dirname, '..', 'public')));
app.use(
  session({
    secret: process.env.SESSION_SECRET || 'dev-secret-change-me',
    resave: false,
    saveUninitialized: false,
    cookie: {
      httpOnly: true,
      sameSite: 'lax',
      secure: process.env.NODE_ENV === 'production'
    }
  })
);

app.use((req, res, next) => {
  res.locals.currentUser = req.session.user;
  res.locals.error = null;
  next();
});

app.get('/health', (req, res) => {
  res.status(200).json({ status: 'ok' });
});

app.get('/', (req, res) => {
  if (!req.session.user) return res.redirect('/login');
  return res.redirect(req.session.user.role === 'admin' ? '/admin' : '/dashboard');
});

app.get('/login', (req, res) => {
  res.render('login', { error: req.query.error });
});

app.post('/login', async (req, res, next) => {
  const { username, password, role } = req.body;

  try {
    const user = await storage.findUser(username, role);

    if (!user || !storage.verifyPassword(user, password)) {
      return res.redirect('/login?error=Invalid%20credentials');
    }

    req.session.user = {
      id: user.id,
      username: user.username,
      role: user.role,
      name: user.name,
      email: user.email
    };

    return res.redirect(user.role === 'admin' ? '/admin' : '/dashboard');
  } catch (error) {
    next(error);
  }
});

app.post('/logout', requireAuth, (req, res) => {
  req.session.destroy(() => res.redirect('/login'));
});

app.get('/dashboard', requireRole('user'), async (req, res, next) => {
  try {
    const claims = await storage.listClaims(req.session.user.id);
    res.render('user-dashboard', { claims });
  } catch (error) {
    next(error);
  }
});

app.get('/claims/new', requireRole('user'), (req, res) => {
  res.render('claim-form');
});

app.post('/claims', requireRole('user'), upload.single('document'), async (req, res, next) => {
  try {
    const claimId = uuidv4();
    const user = req.session.user;

    if (!req.file) {
      return res.status(400).render('error', { message: 'A supporting document is required for validation.' });
    }

    const stagedFile = await storage.saveStagedUploadedFile(user.id, claimId, req.file);
    const now = new Date().toISOString();

    const claim = {
      claimId,
      userId: user.id,
      userName: user.name,
      userEmail: user.email,
      policyNumber: req.body.policyNumber,
      claimType: req.body.claimType,
      incidentDate: req.body.incidentDate,
      claimAmount: Number(req.body.claimAmount || 0),
      contactNumber: req.body.contactNumber,
      description: req.body.description,
      stagedFile,
      uploadedFile: null,
      status: 'PendingValidation',
      validation: {
        status: 'pending',
        requestedAt: now,
        checkedAt: null,
        errors: [],
        extractedTextPreview: ''
      },
      adminFeedback: '',
      createdAt: now,
      updatedAt: now
    };

    await storage.saveClaim(user.id, claim);
    res.redirect('/dashboard');
  } catch (error) {
    next(error);
  }
});

app.get('/files/:userId/:claimId', requireAuth, async (req, res, next) => {
  try {
    const { userId, claimId } = req.params;
    if (req.session.user.role !== 'admin' && req.session.user.id !== userId) {
      return res.status(403).render('error', { message: 'You do not have access to this file.' });
    }

    const claim = await storage.getClaim(userId, claimId);
    if (!claim) {
      return res.status(404).render('error', { message: 'Claim not found.' });
    }

    if (!claim.uploadedFile) {
      return res.status(404).render('error', { message: 'No uploaded file was found for this claim.' });
    }

    const file = await storage.getFile(claim.uploadedFile.blobName);
    if (!file) {
      return res.status(404).render('error', { message: 'The uploaded file is missing from storage.' });
    }

    res.setHeader('Content-Type', claim.uploadedFile.mimeType || file.contentType);
    res.setHeader('Content-Disposition', `attachment; filename="${claim.uploadedFile.originalName}"`);
    res.send(file.buffer);
  } catch (error) {
    next(error);
  }
});

app.get('/admin', requireRole('admin'), async (req, res, next) => {
  try {
    const [claims, users] = await Promise.all([storage.listAllClaims(), storage.listUsers()]);
    res.render('admin-dashboard', { claims, users });
  } catch (error) {
    next(error);
  }
});

app.get('/admin/claims/:userId/:claimId', requireRole('admin'), async (req, res, next) => {
  try {
    const claim = await storage.getClaim(req.params.userId, req.params.claimId);
    if (!claim) {
      return res.status(404).render('error', { message: 'Claim not found.' });
    }

    res.render('admin-claim', { claim });
  } catch (error) {
    next(error);
  }
});

app.post('/admin/claims/:userId/:claimId/feedback', requireRole('admin'), async (req, res, next) => {
  try {
    const claim = await storage.getClaim(req.params.userId, req.params.claimId);
    if (!claim) {
      return res.status(404).render('error', { message: 'Claim not found.' });
    }

    claim.status = req.body.status;
    claim.adminFeedback = req.body.adminFeedback;
    claim.updatedAt = new Date().toISOString();
    await storage.saveClaim(req.params.userId, claim);
    res.redirect('/admin');
  } catch (error) {
    next(error);
  }
});

app.use((req, res) => {
  res.status(404).render('error', { message: 'Page not found.' });
});

app.use((error, req, res, next) => {
  console.error(error);
  res.status(500).render('error', { message: 'Something went wrong while processing the request.' });
});

function requireAuth(req, res, next) {
  if (!req.session.user) return res.redirect('/login');
  next();
}

function requireRole(role) {
  return (req, res, next) => {
    if (!req.session.user) return res.redirect('/login');
    if (req.session.user.role !== role) {
      return res.status(403).render('error', { message: 'You do not have access to this area.' });
    }
    next();
  };
}

const port = process.env.PORT || 3000;

storage
  .init()
  .then(() => {
    app.listen(port, () => {
      console.log(`Insurance claims portal listening on port ${port}`);
    });
  })
  .catch((error) => {
    console.error('Failed to initialize storage', error);
    process.exit(1);
  });
